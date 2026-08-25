# 334.4 — Redes Privadas Virtuales
## Ejercicios guiados — LPIC-3 303 (Examen 303-300, v3.0.0)

**Peso en el examen: 6.67** · Fuente del objetivo: <https://www.lpi.org/our-certifications/exam-303-objectives/>

Estos ejercicios cubren las dos pilas VPN que el objetivo nombra explícitamente — **OpenVPN** (basada en TLS, en espacio de usuario, `tun`/`tap`) y **strongSwan/IPsec** (IKEv2, XFRM del kernel) — más el modo túnel frente al modo transporte y el conocimiento de L2TP. Cada paso se ejecuta; cada archivo de configuración está completo y es sintácticamente válido. No te saltees los comandos de verificación: el examen evalúa *estado observable* (`swanctl --list-sas`, `ip xfrm policy`, el archivo de estado de OpenVPN), no solamente el contenido de los archivos.

---

## Topología del laboratorio

Armá tres máquinas (VMs, contenedores LXC con `net_admin` + `/dev/net/tun`, o invitados KVM). Los network namespaces también funcionan, pero complican la prueba de las units de `systemd`.

```
                        transit segment 198.51.100.0/24
        ┌───────────────────────┐                    ┌───────────────────────┐
        │  gw-a                 │                    │  gw-b                 │
        │  eth0 198.51.100.10   │◄──────────────────►│  eth0 198.51.100.20   │
        │  eth1 192.168.10.1/24 │                    │  eth1 192.168.20.1/24 │
        │  OpenVPN server       │                    │  IPsec peer           │
        │  strongSwan gateway   │                    │  strongSwan gateway   │
        └───────────┬───────────┘                    └───────────┬───────────┘
                    │                                            │
           lan-a 192.168.10.0/24                        lan-b 192.168.20.0/24
           host-a1 192.168.10.50                        host-b1 192.168.20.50

        ┌───────────────────────┐
        │  rw1 (road warrior)   │  eth0 198.51.100.77 — OpenVPN client only
        └───────────────────────┘

        OpenVPN virtual subnet: 10.8.0.0/24
        DNS names used in certificates: gw-a.example.com, gw-b.example.com
```

Agregá esto a `/etc/hosts` en los tres nodos:

```
198.51.100.10   gw-a gw-a.example.com
198.51.100.20   gw-b gw-b.example.com
198.51.100.77   rw1  rw1.example.com
```

Nombres de paquetes por familia:

| Componente | Debian 12 / Ubuntu 24.04 | RHEL 9 / Rocky 9 |
|---|---|---|
| OpenVPN | `openvpn easy-rsa` | `openvpn easy-rsa` (EPEL) |
| strongSwan (swanctl) | `strongswan strongswan-swanctl` | `strongswan` |
| `ipsec` legacy de strongSwan | `strongswan-starter` | incluido (wrapper `ipsec`) |
| Diagnóstico | `tcpdump iproute2 nftables` | `tcpdump iproute2 nftables` |

---

## Ejercicio 1 — Construir una PKI con Easy-RSA 3

**Objetivo:** producir una CA, un certificado de servidor con el Extended Key Usage correcto, un certificado de cliente, una CRL y una clave `tls-crypt`. Todo aquello de lo que depende la autenticación de OpenVPN se crea acá.

### Pasos

1. En `gw-a`, creá un directorio de trabajo para la CA fuera del árbol de OpenVPN (la clave privada de la CA nunca debe vivir en el servidor VPN en producción — acá estás colapsando dos roles para el laboratorio, y conviene que lo sepas):

```bash
sudo apt-get install -y openvpn easy-rsa
make-cadir ~/easy-rsa          # Debian helper; on RHEL: cp -r /usr/share/easy-rsa/3 ~/easy-rsa
cd ~/easy-rsa
```

2. Escribí `~/easy-rsa/vars`. Las claves de curva elíptica son más chicas y más rápidas, y eliminan por completo el archivo de parámetros Diffie-Hellman:

```bash
cat > vars <<'EOF'
set_var EASYRSA_ALGO             ec
set_var EASYRSA_CURVE            secp384r1
set_var EASYRSA_DIGEST           "sha384"
set_var EASYRSA_CA_EXPIRE        3650
set_var EASYRSA_CERT_EXPIRE      825
set_var EASYRSA_CRL_DAYS         180
set_var EASYRSA_REQ_CN           "Example VPN CA"
set_var EASYRSA_BATCH            "1"
EOF
```

3. Inicializá la PKI y construí la CA:

```bash
./easyrsa init-pki
./easyrsa build-ca nopass
```

Cola esperada:

```
CA creation complete and you may now import and sign cert requests.
Your new CA certificate file for publishing is at:
/home/lab/easy-rsa/pki/ca.crt
```

4. Emití el certificado de servidor. El tipo `server` es el que estampa `extendedKeyUsage = serverAuth` y `keyUsage = digitalSignature, keyEncipherment`:

```bash
./easyrsa build-server-full gw-a.example.com nopass
```

5. Emití un certificado de cliente:

```bash
./easyrsa build-client-full roadwarrior1 nopass
```

6. Generá una CRL (inicialmente vacía) e inspeccioná qué contiene realmente:

```bash
./easyrsa gen-crl
openssl crl -in pki/crl.pem -noout -text | head -n 12
```

```
Certificate Revocation List (CRL):
        Version 2 (0x1)
        Signature Algorithm: ecdsa-with-SHA384
        Issuer: CN = Example VPN CA
        Last Update: Aug 25 12:00:00 2026 GMT
        Next Update: Feb 21 12:00:00 2027 GMT
        CRL extensions:
            X509v3 Authority Key Identifier: ...
No Revoked Certificates.
```

7. Demostrá la distinción de EKU entre los dos certificados hoja:

```bash
openssl x509 -in pki/issued/gw-a.example.com.crt -noout -ext extendedKeyUsage,keyUsage
openssl x509 -in pki/issued/roadwarrior1.crt     -noout -ext extendedKeyUsage,keyUsage
```

```
X509v3 Extended Key Usage:
    TLS Web Server Authentication
X509v3 Key Usage:
    Digital Signature, Key Encipherment
---
X509v3 Extended Key Usage:
    TLS Web Client Authentication
X509v3 Key Usage:
    Digital Signature
```

8. Generá la clave del canal de control. Esto *no* es parte de la PKI — es un secreto compartido estático:

```bash
openvpn --genkey secret ~/easy-rsa/pki/tc.key    # OpenVPN 2.5+/2.6 syntax
# OpenVPN 2.4 and older: openvpn --genkey --secret ~/easy-rsa/pki/tc.key
head -n 3 ~/easy-rsa/pki/tc.key
```

```
#
# 2048 bit OpenVPN static key
#
```

9. Instalá el material del lado del servidor y ajustá los permisos:

```bash
sudo install -d -m 0700 /etc/openvpn/server
sudo install -m 0644 pki/ca.crt                          /etc/openvpn/server/
sudo install -m 0644 pki/issued/gw-a.example.com.crt     /etc/openvpn/server/
sudo install -m 0600 pki/private/gw-a.example.com.key    /etc/openvpn/server/
sudo install -m 0600 pki/tc.key                          /etc/openvpn/server/
sudo install -m 0644 pki/crl.pem                         /etc/openvpn/server/
```

### Preguntas de control — Ejercicio 1

1. ¿Por qué `vars` nunca mencionó un `dh.pem`, y en qué circunstancia seguirías necesitando `./easyrsa gen-dh`?
2. Un certificado de cliente y uno de servidor están firmados por la misma CA. Sin verificación de EKU, ¿qué ataque habilita eso contra tus clientes VPN, y qué directiva del cliente de OpenVPN lo bloquea?
3. `tc.key` se generó con `openvpn --genkey`, no con `easyrsa`. ¿Qué capa del protocolo OpenVPN protege, y qué observa en el cable un atacante que *no* la tiene?
4. El paso 9 instala `crl.pem` con modo `0644` mientras que la clave privada queda en `0600`. Más adelante vas a agregar `user nobody` a la configuración del servidor. Explicá por qué `crl.pem` en particular debe seguir siendo legible por todos.
5. `EASYRSA_CRL_DAYS` es 180. ¿Qué le pasa a *cada* cliente que se conecte el día 181 si no hacés nada?

---

## Ejercicio 2 — Servidor OpenVPN enrutado (`tun`, `topology subnet`)

**Objetivo:** un servidor IPv4 enrutado funcionando, iniciado a través de la unit template de systemd correcta, con forwarding y NAT para la LAN que tiene detrás.

### Pasos

1. En `gw-a`, escribí `/etc/openvpn/server/server.conf`:

```conf
# ---- transport ----------------------------------------------------------
port 1194
proto udp4
dev tun
topology subnet

# ---- virtual network ----------------------------------------------------
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/lib/openvpn/ipp.txt
push "route 192.168.10.0 255.255.255.0"
push "dhcp-option DNS 192.168.10.1"
client-config-dir /etc/openvpn/server/ccd
route 192.168.20.0 255.255.255.0            # prepared for Exercise 4

# ---- cryptography -------------------------------------------------------
ca      /etc/openvpn/server/ca.crt
cert    /etc/openvpn/server/gw-a.example.com.crt
key     /etc/openvpn/server/gw-a.example.com.key
tls-crypt /etc/openvpn/server/tc.key
crl-verify /etc/openvpn/server/crl.pem
remote-cert-tls client
tls-version-min 1.2
data-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA256

# ---- liveness and hygiene ----------------------------------------------
keepalive 10 60
persist-key
persist-tun
user nobody
group nogroup                                # RHEL: group nobody
explicit-exit-notify 1

# ---- observability ------------------------------------------------------
status /run/openvpn-server/status-server.log 10
status-version 2
verb 3
management 127.0.0.1 7505
```

2. Creá los directorios que referencia la configuración y validá la sintaxis sin arrancar el demonio:

```bash
sudo install -d -m 0755 /etc/openvpn/server/ccd /var/lib/openvpn /run/openvpn-server
sudo openvpn --config /etc/openvpn/server/server.conf --verb 4 --mode server
```

Esperá la línea de finalización y después apretá `Ctrl-C`:

```
2026-08-25 12:00:01 OpenVPN 2.6.9 x86_64-pc-linux-gnu [SSL (OpenSSL)] [LZ4] [EPOLL] [AEAD]
2026-08-25 12:00:01 library versions: OpenSSL 3.0.13 30 Jan 2024, LZ4 1.9.4
2026-08-25 12:00:01 net_iface_up: set tun0 up
2026-08-25 12:00:01 net_addr_v4_add: 10.8.0.1/24 dev tun0
2026-08-25 12:00:01 UDPv4 link local (bound): [AF_INET][undef]:1194
2026-08-25 12:00:01 GID set to nogroup
2026-08-25 12:00:01 UID set to nobody
2026-08-25 12:00:01 Initialization Sequence Completed
```

3. Habilitá el forwarding IPv4 de forma persistente:

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-vpn.conf
sudo sysctl --system | grep -m1 ip_forward
```

```
net.ipv4.ip_forward = 1
```

4. Abrí el puerto y hacé NAT de los clientes VPN hacia la LAN. **nftables:**

```bash
sudo nft -f - <<'EOF'
table inet vpn {
  chain input {
    type filter hook input priority filter; policy accept;
    udp dport 1194 accept
    iifname "tun0" accept
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "tun0" oifname "eth1" accept
    iifname "eth1" oifname "tun0" ct state established,related accept
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 10.8.0.0/24 oifname "eth1" masquerade
  }
}
EOF
```

**Equivalente en firewalld:**

```bash
sudo firewall-cmd --permanent --add-service=openvpn
sudo firewall-cmd --permanent --zone=trusted --add-interface=tun0
sudo firewall-cmd --permanent --add-masquerade
sudo firewall-cmd --reload
```

5. Arrancá el demonio a través de la unit template. El nombre de la instancia es el *basename* del archivo de configuración:

```bash
sudo systemctl enable --now openvpn-server@server.service
systemctl status openvpn-server@server.service --no-pager -l | head -n 8
```

```
● openvpn-server@server.service - OpenVPN service for server
     Loaded: loaded (/lib/systemd/system/openvpn-server@.service; enabled)
     Active: active (running) since Tue 2026-08-25 12:03:11 UTC; 4s ago
```

6. Confirmá el resultado del lado del kernel:

```bash
ip -4 addr show dev tun0
ip -4 route show | grep -E '10\.8\.0|192\.168\.20'
ss -lunp | grep 1194
```

```
4: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500 ...
    inet 10.8.0.1/24 scope global tun0
10.8.0.0/24 dev tun0 proto kernel scope link src 10.8.0.1
192.168.20.0/24 dev tun0 scope link
UNCONN 0 0 0.0.0.0:1194 0.0.0.0:* users:(("openvpn",pid=1841,fd=6))
```

### Preguntas de control — Ejercicio 2

6. Con `topology subnet`, `tun0` en el servidor es `10.8.0.1/24`. ¿Qué distribución de direcciones habría producido `topology net30` en su lugar, para el servidor y para el primer cliente, y por qué existe siquiera el modo legacy?
7. `route 192.168.20.0 255.255.255.0` está en la configuración del servidor pero todavía ningún cliente anuncia esa subred. ¿Qué hizo esa línea en la tabla de rutas del kernel *del servidor* (mirá la salida del paso 6), y qué **no** hizo?
8. El demonio corre como `nobody`, y sin embargo creó `tun0` e instaló rutas. Explicá el orden que hace esto posible, y decí con precisión qué previenen `persist-tun` y `persist-key` después de un reinicio por `SIGUSR1`.
9. Cambiaste `data-ciphers` en el servidor pero un cliente viejo 2.4 igual se conecta correctamente con AES-256-CBC. ¿Qué directiva lo hizo posible, y por qué es una decisión de seguridad y no una comodidad de compatibilidad?
10. `explicit-exit-notify 1` es acá una directiva del lado del servidor. ¿Qué hace el peer con eso, y por qué carece de sentido cuando se usa `proto tcp`?

---

## Ejercicio 3 — Conexión del cliente, verificación en vivo y diagnóstico a nivel de cable

**Objetivo:** conectar `rw1`, demostrar que el túnel transporta tráfico y leer el flujo cifrado en el enlace de tránsito.

### Pasos

1. En `gw-a`, generá un perfil de cliente en un único archivo con todo inline (este es el formato que le entregás a los usuarios — sin archivos de clave sueltos):

```bash
cd ~/easy-rsa
{
  cat <<'EOF'
client
dev tun
proto udp4
remote gw-a.example.com 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name gw-a.example.com name
data-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA256
verb 3
EOF
  echo '<ca>';        cat pki/ca.crt;                        echo '</ca>'
  echo '<cert>';      openssl x509 -in pki/issued/roadwarrior1.crt; echo '</cert>'
  echo '<key>';       cat pki/private/roadwarrior1.key;      echo '</key>'
  echo '<tls-crypt>'; cat pki/tc.key;                        echo '</tls-crypt>'
} > roadwarrior1.ovpn
```

2. Copialo a `rw1` como `/etc/openvpn/client/roadwarrior1.conf` y conectate primero en primer plano, con verbosidad 4:

```bash
sudo openvpn --config /etc/openvpn/client/roadwarrior1.conf --verb 4
```

Líneas clave a identificar:

```
2026-08-25 12:06:02 TCP/UDP: Preserving recently used remote address: [AF_INET]198.51.100.10:1194
2026-08-25 12:06:02 VERIFY OK: depth=1, CN=Example VPN CA
2026-08-25 12:06:02 VERIFY KU OK
2026-08-25 12:06:02 Validating certificate extended key usage
2026-08-25 12:06:02 ++ Certificate has EKU (str) TLS Web Server Authentication, expects TLS Web Server Authentication
2026-08-25 12:06:02 VERIFY EKU OK
2026-08-25 12:06:02 VERIFY X509NAME OK: CN=gw-a.example.com
2026-08-25 12:06:02 VERIFY OK: depth=0, CN=gw-a.example.com
2026-08-25 12:06:02 Control Channel: TLSv1.3, cipher TLSv1.3 TLS_AES_256_GCM_SHA384, peer certificate: 384 bit EC
2026-08-25 12:06:02 [gw-a.example.com] Peer Connection Initiated with [AF_INET]198.51.100.10:1194
2026-08-25 12:06:04 PUSH: Received control message: 'PUSH_REPLY,route 192.168.10.0 255.255.255.0,dhcp-option DNS 192.168.10.1,route-gateway 10.8.0.1,topology subnet,ping 10,ping-restart 60,ifconfig 10.8.0.2 255.255.255.0'
2026-08-25 12:06:04 Outgoing Data Channel: Cipher 'AES-256-GCM' initialized with 256 bit key
2026-08-25 12:06:04 net_addr_v4_add: 10.8.0.2/24 dev tun0
2026-08-25 12:06:04 net_route_v4_add: 192.168.10.0/24 via 10.8.0.1 dev [NULL] table 0
2026-08-25 12:06:04 Initialization Sequence Completed
```

3. Desde una segunda shell en `rw1`, verificá la alcanzabilidad y las rutas resultantes:

```bash
ip -4 route show | grep -E '10\.8|192\.168\.10'
ping -c2 10.8.0.1
ping -c2 192.168.10.50
traceroute -n 192.168.10.50
```

```
10.8.0.0/24 dev tun0 proto kernel scope link src 10.8.0.2
192.168.10.0/24 via 10.8.0.1 dev tun0
```

4. En `gw-a`, leé la tabla de sesiones en vivo de dos maneras:

```bash
sudo cat /run/openvpn-server/status-server.log
```

```
TITLE,OpenVPN 2.6.9 x86_64-pc-linux-gnu [SSL (OpenSSL)] [LZ4] [EPOLL] [AEAD]
TIME,2026-08-25 12:07:00,1787832420
HEADER,CLIENT_LIST,Common Name,Real Address,Virtual Address,Virtual IPv6 Address,Bytes Received,Bytes Sent,Connected Since,Connected Since (time_t),Username,Client ID,Peer ID,Data Channel Cipher
CLIENT_LIST,roadwarrior1,198.51.100.77:44311,10.8.0.2,,4820,4212,2026-08-25 12:06:02,1787832362,UNDEF,0,0,AES-256-GCM
HEADER,ROUTING_TABLE,Virtual Address,Common Name,Real Address,Last Ref,Last Ref (time_t)
ROUTING_TABLE,10.8.0.2,roadwarrior1,198.51.100.77:44311,2026-08-25 12:06:58,1787832418
GLOBAL_STATS,Max bcast/mcast queue length,0
END
```

```bash
printf 'status 2\nquit\n' | nc 127.0.0.1 7505
```

5. Capturá el enlace de tránsito en `gw-a` mientras hacés ping desde `rw1`, y confirmá que el payload es opaco:

```bash
sudo tcpdump -n -i eth0 -c 4 -vv udp port 1194
```

```
12:08:14.220118 IP (tos 0x0, ttl 64, id 0, offset 0, flags [DF], proto UDP (17), length 133)
    198.51.100.77.44311 > 198.51.100.10.1194: UDP, length 105
12:08:14.220944 IP (tos 0x0, ttl 64, id 61553, offset 0, flags [none], proto UDP (17), length 133)
    198.51.100.10.1194 > 198.51.100.77.44311: UDP, length 105
```

Después capturá en la interfaz virtual y mirá el texto plano:

```bash
sudo tcpdump -n -i tun0 -c 4 icmp
```

```
12:08:20.113400 IP 10.8.0.2 > 192.168.10.50: ICMP echo request, id 12, seq 1, length 64
12:08:20.114001 IP 192.168.10.50 > 10.8.0.2: ICMP echo reply,   id 12, seq 1, length 64
```

6. Reproducí el clásico fallo de MTU. Enviá un paquete grande y no fragmentable a través del túnel:

```bash
ping -c1 -M do -s 1450 192.168.10.50
```

```
PING 192.168.10.50 (192.168.10.50) 1450(1478) bytes of data.
ping: local error: message too long, mtu=1500
--- 192.168.10.50 ping statistics ---
1 packets transmitted, 0 received, +1 errors, 100% packet loss
```

Ahora confirmá el techo que sí funciona y registralo:

```bash
for s in 1500 1450 1400 1380 1360; do
  ping -c1 -W1 -M do -s $s 192.168.10.50 >/dev/null 2>&1 && echo "$s OK" || echo "$s FAIL"
done
```

7. Forzá un fallo controlado para aprender su firma. En `rw1`, quitá el bloque `<tls-crypt>` de una copia del perfil y conectate:

```bash
sudo openvpn --config /etc/openvpn/client/broken.conf --verb 3
```

```
2026-08-25 12:11:02 TLS Error: cannot locate HMAC in incoming packet from [AF_INET]198.51.100.10:1194
2026-08-25 12:12:02 TLS Error: TLS key negotiation failed to occur within 60 seconds (check your network connectivity)
2026-08-25 12:12:02 TLS Error: TLS handshake failed
```

Mientras tanto, el **log del servidor no dice nada sobre este cliente**. Confirmalo:

```bash
sudo journalctl -u openvpn-server@server -n 20 --no-pager
```

### Preguntas de control — Ejercicio 3

11. En el paso 2 aparecen cuatro líneas `VERIFY` distintas. Asociá cada una con la directiva del cliente que la solicitó, y decí cuáles de las cuatro seguirían disparándose si se quitara `remote-cert-tls server`.
12. `PUSH_REPLY` contiene `ifconfig 10.8.0.2 255.255.255.0` y `route-gateway 10.8.0.1`. Ninguna de las dos aparece en el archivo de configuración propio del cliente. ¿Cuál es la consecuencia de seguridad de que un cliente confíe en directivas empujadas, y qué directiva del lado del cliente la limita?
13. El paso 5 muestra UDP length 105 para un payload ICMP de 64 bytes. Justificá el crecimiento, y explicá por qué un observador en la ruta igual puede inferir el *tipo* de tráfico pese al cifrado.
14. Paso 6: el fallo con 1450 bytes lo reporta la pila *local*, no un router remoto. Explicá el mecanismo, y después decí qué directiva de OpenVPN arregla el throughput de TCP sin tocar la MTU del cliente, y por qué esa directiva no hace nada para aplicaciones basadas en UDP como DNS-over-QUIC.
15. En el paso 7 el servidor no registró absolutamente nada. Explicá exactamente qué le hizo `tls-crypt` al primer paquete del cliente para producir ese silencio, y nombrá un beneficio operativo y un costo de troubleshooting de este comportamiento.
16. `tls-crypt` frente a `tls-auth`: enunciá las dos diferencias funcionales, y explicá qué agrega `tls-crypt-v2` que ninguna de las dos provee.

---

## Ejercicio 4 — Client-config-dir, `iroute` y revocación de certificados

**Objetivo:** fijar un cliente a una dirección VPN estable, enrutar una subred remota completa a través de un cliente (el patrón site-to-site de OpenVPN) y demostrar que la revocación funciona.

### Pasos

1. En `gw-a`, fijá la dirección del road warrior. El nombre del archivo **debe ser igual al CN del certificado**:

```bash
sudo tee /etc/openvpn/server/ccd/roadwarrior1 <<'EOF'
ifconfig-push 10.8.0.50 255.255.255.0
EOF
```

2. Emití un certificado para un gateway de sucursal que va a presentar la red 192.168.20.0/24, y dale la ruta interna:

```bash
cd ~/easy-rsa && ./easyrsa build-client-full branch-b nopass
sudo tee /etc/openvpn/server/ccd/branch-b <<'EOF'
ifconfig-push 10.8.0.60 255.255.255.0
iroute 192.168.20.0 255.255.255.0
EOF
```

3. Reiniciá el servidor y reconectá `rw1`; confirmá la dirección fijada:

```bash
sudo systemctl restart openvpn-server@server
# on rw1, reconnect, then:
ip -4 addr show dev tun0 | grep inet
```

```
    inet 10.8.0.50/24 scope global tun0
```

4. Agregá la mitad faltante del camino site-to-site. `gw-a` ya tiene `route 192.168.20.0 255.255.255.0`; los demás clientes VPN también la necesitan, así que empujala:

```bash
sudo tee -a /etc/openvpn/server/server.conf <<'EOF'
push "route 192.168.20.0 255.255.255.0"
EOF
sudo systemctl restart openvpn-server@server
```

5. Ahora revocá el road warrior y regenerá la CRL:

```bash
cd ~/easy-rsa
./easyrsa revoke roadwarrior1
./easyrsa gen-crl
sudo install -m 0644 pki/crl.pem /etc/openvpn/server/crl.pem
openssl crl -in pki/crl.pem -noout -text | grep -A2 'Serial Number'
```

```
    Serial Number: 5C3A1F0B9D24E6A7
        Revocation Date: Aug 25 12:20:11 2026 GMT
```

6. **Sin reiniciar el servidor**, reconectá `rw1` y leé ambos lados:

Cliente:

```
2026-08-25 12:21:03 VERIFY ERROR: depth=0, error=CRL signature failure: CN=roadwarrior1
2026-08-25 12:21:03 TLS_ERROR: BIO read tls_read_plaintext error
2026-08-25 12:21:03 TLS Error: TLS handshake failed
```

Servidor:

```
2026-08-25 12:21:03 198.51.100.77:44870 VERIFY ERROR: depth=0, error=certificate revoked: CN=roadwarrior1, serial=5C3A1F0B9D24E6A7
2026-08-25 12:21:03 198.51.100.77:44870 OpenSSL: error:0A000418:SSL routines::tlsv1 alert unknown ca
```

7. Verificá que el demonio en ejecución todavía puede leer la CRL después de bajar privilegios — acá es donde el ejercicio suele romperse en el mundo real:

```bash
sudo -u nobody test -r /etc/openvpn/server/crl.pem && echo "readable by nobody" || echo "PRIVILEGE DROP WILL BREAK CRL"
sudo namei -l /etc/openvpn/server/crl.pem
```

8. Desconectá un cliente administrativamente sin tocar su certificado:

```bash
printf 'kill branch-b\nquit\n' | nc 127.0.0.1 7505
```

```
SUCCESS: common name 'branch-b' found, 1 client(s) killed
```

### Preguntas de control — Ejercicio 4

17. Distinguí `route 192.168.20.0 255.255.255.0` (configuración del servidor), `push "route 192.168.20.0 255.255.255.0"` e `iroute 192.168.20.0 255.255.255.0` (archivo ccd). ¿Qué tabla de rutas o estructura interna modifica cada una, y qué se rompe si omitís solamente el `iroute`?
18. El archivo ccd debe llamarse igual que el CN del certificado. ¿Qué pasa si el archivo no existe, y qué directiva del servidor convierte esa condición silenciosa en un rechazo duro?
19. La revocación surtió efecto sin reiniciar el servicio. Describí cuándo relee OpenVPN el `crl.pem`, y explicá el modo de fallo cuando se combina `chroot` con `crl-verify`.
20. En el paso 7 verificaste la legibilidad *como `nobody`*. Describí el síntoma exacto que muestra un servidor que funciona pero está mal configurado cuando la CRL queda ilegible tras bajar privilegios — y por qué es discutiblemente peor que un crash.
21. `kill branch-b` en la interfaz de management desconecta al cliente, pero este se reconecta segundos después. ¿Por qué, y cuál es el remedio duradero correcto?
22. `verify-x509-name gw-a.example.com name` está en el cliente. Si un atacante roba una clave de *cliente* de tu PKI y levanta un servidor pirata con ella, ¿esta directiva detiene el ataque? ¿Y `remote-cert-tls server`? Justificá ambas respuestas.

---

## Ejercicio 5 — Túnel site-to-site IKEv2 con strongSwan usando `swanctl` (PSK)

**Objetivo:** un túnel IPsec en modo kernel entre `gw-a` y `gw-b` que une 192.168.10.0/24 y 192.168.20.0/24, configurado con la interfaz moderna `swanctl.conf`/VICI.

### Pasos

1. Instalá en **ambos** gateways y confirmá qué variante del demonio está corriendo:

```bash
sudo apt-get install -y strongswan strongswan-swanctl   # RHEL: dnf install -y strongswan
systemctl list-unit-files | grep -i strongswan
```

```
strongswan-starter.service   enabled     # legacy ipsec/starter/stroke
strongswan.service           enabled     # charon-systemd, driven by swanctl
```

Deshabilitá el legacy para que los dos no se peleen por las mismas SAs:

```bash
sudo systemctl disable --now strongswan-starter.service
sudo systemctl enable  --now strongswan.service
```

2. Habilitá el forwarding en ambos gateways y **excluí el tráfico IPsec del NAT** (una regla de masquerade que atrape 192.168.10.0/24 → 192.168.20.0/24 va a reescribir la dirección de origen antes de que coincida la política XFRM, y el túnel va a transportar nada, en silencio):

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo nft insert rule inet vpn postrouting ip saddr 192.168.10.0/24 ip daddr 192.168.20.0/24 accept
```

3. En `gw-a`, escribí `/etc/swanctl/swanctl.conf`:

```conf
connections {
    a-to-b {
        version      = 2
        local_addrs  = 198.51.100.10
        remote_addrs = 198.51.100.20
        proposals    = aes256-sha256-modp3072,aes256gcm16-prfsha384-ecp384

        local {
            auth = psk
            id   = gw-a.example.com
        }
        remote {
            auth = psk
            id   = gw-b.example.com
        }

        children {
            net-net {
                local_ts      = 192.168.10.0/24
                remote_ts     = 192.168.20.0/24
                mode          = tunnel
                esp_proposals = aes256gcm16-ecp384,aes256-sha256-modp3072
                start_action  = trap
                close_action  = trap
                dpd_action    = restart
                rekey_time    = 1h
                life_time     = 1h20m
            }
        }

        rekey_time  = 4h
        over_time   = 10m
        dpd_delay   = 30s
        dpd_timeout = 120s
        mobike      = no
    }
}

secrets {
    ike-a-b {
        id-local  = gw-a.example.com
        id-remote = gw-b.example.com
        secret    = "3xAmpl3-Lab-PSK-Do-Not-Use-In-Production-9f2c"
    }
}
```

4. En `gw-b`, escribí la imagen especular. Solo se intercambian las cuatro líneas de direcciones/IDs/selectores de tráfico:

```conf
connections {
    b-to-a {
        version      = 2
        local_addrs  = 198.51.100.20
        remote_addrs = 198.51.100.10
        proposals    = aes256-sha256-modp3072,aes256gcm16-prfsha384-ecp384

        local  { auth = psk; id = gw-b.example.com }
        remote { auth = psk; id = gw-a.example.com }

        children {
            net-net {
                local_ts      = 192.168.20.0/24
                remote_ts     = 192.168.10.0/24
                mode          = tunnel
                esp_proposals = aes256gcm16-ecp384,aes256-sha256-modp3072
                start_action  = trap
                close_action  = trap
                dpd_action    = restart
            }
        }
        dpd_delay = 30s
    }
}

secrets {
    ike-a-b {
        id-local  = gw-b.example.com
        id-remote = gw-a.example.com
        secret    = "3xAmpl3-Lab-PSK-Do-Not-Use-In-Production-9f2c"
    }
}
```

5. Asegurá el archivo y cargá la configuración en el demonio en ejecución en ambos nodos:

```bash
sudo chmod 0600 /etc/swanctl/swanctl.conf
sudo swanctl --load-all
```

```
loaded ike secret 'ike-a-b'
no authorities found, 0 unloaded
no pools found, 0 unloaded
loaded connection 'a-to-b'
successfully loaded 1 connections, 0 unloaded
```

6. Inspeccioná lo que el demonio cree *antes* de que fluya tráfico alguno:

```bash
sudo swanctl --list-conns
sudo ip xfrm policy
sudo ip xfrm state
```

```
a-to-b: IKEv2, no reauthentication, rekeying every 14400s
  local:  198.51.100.10
  remote: 198.51.100.20
  local pre-shared key authentication:
    id: gw-a.example.com
  remote pre-shared key authentication:
    id: gw-b.example.com
  net-net: TUNNEL, rekeying every 3600s
    local:  192.168.10.0/24
    remote: 192.168.20.0/24
```

```
src 192.168.10.0/24 dst 192.168.20.0/24
	dir out priority 375423 ptype main
	tmpl src 198.51.100.10 dst 198.51.100.20
		proto esp spi 0x00000000 reqid 1 mode tunnel
```

(`ip xfrm state` no imprime nada.)

7. Disparó el túnel desde el lado LAN y observá cómo se levanta:

```bash
# from host-a1
ping -c3 192.168.20.50
```

```bash
# on gw-a
sudo swanctl --list-sas
```

```
a-to-b: #1, ESTABLISHED, IKEv2, 8e1c4d5f6a7b8c9d_i* 1a2b3c4d5e6f7a8b_r
  local  'gw-a.example.com' @ 198.51.100.10[500]
  remote 'gw-b.example.com' @ 198.51.100.20[500]
  AES_CBC-256/HMAC_SHA2_256_128/PRF_HMAC_SHA2_256/MODP_3072
  established 3s ago, rekeying in 13102s
  net-net: #1, reqid 1, INSTALLED, TUNNEL, ESP:AES_GCM_16-256
    installed 3s ago, rekeying in 3204s, expires in 4797s
    in  c1a2b3c4,    252 bytes,     3 packets,     1s ago
    out d4e5f6a7,    252 bytes,     3 packets,     1s ago
    local  192.168.10.0/24
    remote 192.168.20.0/24
```

8. Leé la visión del kernel — esta es la verdad de base, independiente del demonio:

```bash
sudo ip -s xfrm state
sudo ip xfrm policy | grep -c 'dir'
```

```
src 198.51.100.10 dst 198.51.100.20
	proto esp spi 0xd4e5f6a7 reqid 1 mode tunnel
	replay-window 0 flag af-unspec esn
	aead rfc4106(gcm(aes)) 0x9a3f... 128
	lifetime config:
	  limit: soft (none), hard (none)
	  expire add: soft 3204(sec), hard 4797(sec)
	stats:
	  replay-window 0 replay 0 failed 0
```

```
3
```

9. Demostrá en el cable que esto es ESP, no UDP:

```bash
sudo tcpdump -n -i eth0 -c 4 esp
```

```
12:35:41.113221 IP 198.51.100.10 > 198.51.100.20: ESP(spi=0xd4e5f6a7,seq=0x4), length 120
12:35:41.114008 IP 198.51.100.20 > 198.51.100.10: ESP(spi=0xc1a2b3c4,seq=0x4), length 120
```

10. Notá que **no hay ninguna interfaz** para este túnel:

```bash
ip -br link show | grep -Ev 'lo|eth'
```

(sin salida — compará con `tun0` del Ejercicio 2.)

### Preguntas de control — Ejercicio 5

23. En el paso 6, `ip xfrm policy` ya contenía una entrada con `spi 0x00000000` mientras `ip xfrm state` estaba vacío. Nombrá el ajuste de strongSwan que lo produjo y explicá la máquina de estados que implementa.
24. `ip xfrm policy | grep -c dir` devolvió **3** para un solo túnel. Nombrá las tres direcciones y decí cuál se requiere específicamente porque esta máquina es un *gateway* y no un endpoint.
25. `swanctl --list-sas` muestra una IKE SA y una CHILD SA, con SPIs `in`/`out` separados. Explicá la relación entre IKE SA, CHILD SA y SPI, y cuál de ellos elige el *responder*.
26. El paso 10 muestra que no existe ninguna interfaz. Contrastalo con el `tun0` de OpenVPN y dá dos consecuencias operativas concretas (una para el filtrado y otra para el monitoreo).
27. El paso 2 insertó una regla `accept` delante del masquerade. Describí el camino exacto del paquete que sale mal sin ella, y nombrá el síntoma que reportaría un operador.
28. `start_action = trap` frente a `start_action = start`: enunciá la diferencia de comportamiento y elegí la opción correcta para (a) una sucursal que siempre debe ser alcanzable desde la casa central, (b) un enlace LTE de respaldo con tarifa medida.
29. Ambos lados declaran `mobike = no`. ¿Qué hace MOBIKE, en qué versión de IKE está disponible, y por qué es irrelevante para un túnel site-to-site de direcciones fijas pero esencial para una laptop?

---

## Ejercicio 6 — Autenticación por certificados y modo transporte

**Objetivo:** reemplazar la PSK por autenticación X.509 usando la herramienta `pki` propia de strongSwan, después construir una SA host-to-host en **modo transporte** y observar la diferencia en la política del kernel.

### Pasos

1. En `gw-a`, construí una CA IPsec separada (no reutilices la CA de OpenVPN — dominio de confianza distinto, ciclo de vida de revocación distinto):

```bash
cd /tmp && umask 077
pki --gen --type ed25519 --outform pem > ipsec-ca.key
pki --self --ca --lifetime 3650 --in ipsec-ca.key --type ed25519 \
    --dn "C=AR, O=Example, CN=Example IPsec CA" --outform pem > ipsec-ca.crt

for host in gw-a gw-b; do
  pki --gen --type ed25519 --outform pem > ${host}.key
  pki --pub --in ${host}.key --type ed25519 \
   | pki --issue --lifetime 825 --cacert ipsec-ca.crt --cakey ipsec-ca.key \
         --dn "C=AR, O=Example, CN=${host}.example.com" \
         --san ${host}.example.com --flag serverAuth --flag ikeIntermediate \
         --outform pem > ${host}.crt
done
pki --print --in gw-a.crt | head -n 8
```

```
  subject:  "C=AR, O=Example, CN=gw-a.example.com"
  issuer:   "C=AR, O=Example, CN=Example IPsec CA"
  validity:  not before Aug 25 12:40:00 2026, ok
             not after  Nov 27 12:40:00 2028, ok
  serial:    3f:1a:9c:22:0e:47:b5:d8
  altNames:  gw-a.example.com
  flags:     serverAuth ikeIntermediate
  authkeyId: 5a:cc:...
  subjkeyId: 91:2e:...
```

2. Colocá las credenciales en los directorios que escanea `swanctl --load-creds`:

```bash
# on gw-a
sudo install -m 0644 ipsec-ca.crt /etc/swanctl/x509ca/
sudo install -m 0644 gw-a.crt     /etc/swanctl/x509/
sudo install -m 0600 gw-a.key     /etc/swanctl/private/
# copy ipsec-ca.crt, gw-b.crt, gw-b.key to gw-b's matching directories
ls -R /etc/swanctl | head -n 20
```

3. Cambiá la conexión de `gw-a` a autenticación de clave pública:

```conf
connections {
    a-to-b {
        version      = 2
        local_addrs  = 198.51.100.10
        remote_addrs = 198.51.100.20
        proposals    = aes256gcm16-prfsha384-ecp384

        local {
            auth  = pubkey
            certs = gw-a.crt
            id    = "C=AR, O=Example, CN=gw-a.example.com"
        }
        remote {
            auth = pubkey
            id   = "C=AR, O=Example, CN=gw-b.example.com"
        }

        children {
            net-net {
                local_ts      = 192.168.10.0/24
                remote_ts     = 192.168.20.0/24
                mode          = tunnel
                esp_proposals = aes256gcm16-ecp384
                start_action  = trap
            }
            host-host {
                local_ts      = 198.51.100.10/32
                remote_ts     = 198.51.100.20/32
                mode          = transport
                esp_proposals = aes256gcm16-ecp384
                start_action  = none
            }
        }
    }
}
```

Reflejalo en `gw-b` (intercambiando direcciones, IDs, `certs` y los dos selectores de tráfico).

4. Recargá credenciales y conexiones en ambos lados, y después verificá qué se cargó realmente:

```bash
sudo swanctl --load-creds
sudo swanctl --load-conns
sudo swanctl --list-certs --subject gw-a.example.com
```

```
loaded certificate from '/etc/swanctl/x509ca/ipsec-ca.crt'
loaded certificate from '/etc/swanctl/x509/gw-a.crt'
loaded ED25519 key from '/etc/swanctl/private/gw-a.key'
successfully loaded 1 connections, 0 unloaded
```

5. Iniciá explícitamente el child en modo transporte y compará las dos políticas lado a lado:

```bash
sudo swanctl --initiate --child host-host
sudo swanctl --list-sas --raw | head -n 3
sudo ip xfrm policy
```

```
src 198.51.100.10/32 dst 198.51.100.20/32
	dir out priority 383359 ptype main
	tmpl src 0.0.0.0 dst 0.0.0.0
		proto esp spi 0x00000000 reqid 2 mode transport
src 192.168.10.0/24 dst 192.168.20.0/24
	dir out priority 375423 ptype main
	tmpl src 198.51.100.10 dst 198.51.100.20
		proto esp reqid 1 mode tunnel
```

6. Capturá ambas y compará la profundidad de las cabeceras:

```bash
sudo tcpdump -n -i eth0 -c 2 -e esp
```

7. Rompé la autenticación deliberadamente: en `gw-b`, cambiá `remote { id = ... }` a `CN=wrong.example.com`, recargá y volvé a iniciar desde `gw-a`:

```bash
sudo swanctl --initiate --child net-net
```

```
initiating IKE_SA a-to-b[3] to 198.51.100.20
...
received AUTHENTICATION_FAILED notify error
establishing connection 'a-to-b' failed
```

El journal de `gw-b`:

```
journalctl -u strongswan -n 5 --no-pager
charon: 09[CFG] no matching peer config found for 'C=AR, O=Example, CN=gw-b.example.com'...'C=AR, O=Example, CN=gw-a.example.com'
charon: 09[ENC] generating IKE_AUTH response ... N(AUTH_FAILED)
```

Restaurá el ID correcto y confirmá la recuperación.

8. Forzá un desajuste de propuestas: en `gw-b` poné `esp_proposals = aes128-sha1-modp1024`, recargá e iniciá desde `gw-a`:

```
received NO_PROPOSAL_CHOSEN notify, no CHILD_SA built
```

Restaurá.

### Preguntas de control — Ejercicio 6

30. En el paso 5 la política en modo transporte muestra `tmpl src 0.0.0.0 dst 0.0.0.0` mientras que la de modo túnel muestra direcciones reales de gateway. Explicá por qué, en términos de lo que cada modo le hace a la cabecera IP original.
31. ¿Por qué el modo transporte nunca puede usarse para unir 192.168.10.0/24 con 192.168.20.0/24?
32. Se le pasó `--flag ikeIntermediate` a `pki --issue`. ¿Para qué sirve, y es necesario para IKEv2?
33. `swanctl --load-creds` lee `/etc/swanctl/private`, `/etc/swanctl/x509`, `/etc/swanctl/x509ca` y `/etc/swanctl/x509crl`. ¿Cuál debe estar poblado para que se valide la identidad del peer *remoto*, y por qué no hace falta que el certificado propio del peer remoto esté presente localmente?
34. Contrastá los dos fallos inducidos: `AUTHENTICATION_FAILED` (paso 7) y `NO_PROPOSAL_CHOSEN` (paso 8). ¿En qué intercambio de IKEv2 ocurre cada uno, y qué te dice eso sobre cuál es visible para un atacante no autenticado?
35. Acá el `local.id` es un distinguished name completo, pero en el Ejercicio 5 era un FQDN. ¿A qué debe corresponder el `id` cuando `auth = pubkey`, y qué error resulta de un desajuste con el subject o el SAN del certificado?

---

## Ejercicio 7 — `ipsec.conf` / `ipsec.secrets` legacy, `strongswan.conf` y conocimiento de L2TP

**Objetivo:** leer y escribir la configuración más vieja de `starter`/`stroke` que el examen todavía lista, ajustar `charon` y entender dónde encaja L2TP.

### Pasos

1. Detené el demonio manejado por swanctl para que los dos no entren en conflicto, y pasate al legacy:

```bash
sudo systemctl stop strongswan.service
sudo systemctl start strongswan-starter.service   # RHEL: the 'ipsec' wrapper starts this
```

2. Expresá el túnel del Ejercicio 5 en `/etc/ipsec.conf`:

```conf
config setup
    charondebug = "ike 1, knl 1, cfg 0"
    uniqueids   = yes

conn %default
    keyexchange  = ikev2
    ike          = aes256-sha256-modp3072!
    esp          = aes256gcm16-ecp384!
    dpdaction    = restart
    dpddelay     = 30s
    closeaction  = restart

conn a-to-b
    left         = 198.51.100.10
    leftid       = gw-a.example.com
    leftsubnet   = 192.168.10.0/24
    leftauth     = psk
    right        = 198.51.100.20
    rightid      = gw-b.example.com
    rightsubnet  = 192.168.20.0/24
    rightauth    = psk
    type         = tunnel
    auto         = route
```

3. Y `/etc/ipsec.secrets` (modo `0600`):

```
gw-a.example.com gw-b.example.com : PSK "3xAmpl3-Lab-PSK-Do-Not-Use-In-Production-9f2c"
```

```bash
sudo chmod 0600 /etc/ipsec.secrets
```

4. Cargá e inspeccioná con las herramientas legacy:

```bash
sudo ipsec restart
sleep 3
sudo ipsec statusall | head -n 20
```

```
Status of IKE charon daemon (strongSwan 5.9.11, Linux 6.1.0, x86_64):
  uptime: 3 seconds, since Aug 25 12:55:02 2026
  malloc: sbrk 2314240, mmap 0, used 494096, free 1820144
  worker threads: 11 of 16 idle, 5/0/0/0 working, job queue: 0/0/0/0
  loaded plugins: charon aes sha2 random nonce x509 pubkey pem openssl kernel-netlink socket-default stroke vici updown
Listening IP addresses:
  198.51.100.10
  192.168.10.1
Connections:
      a-to-b:  198.51.100.10...198.51.100.20  IKEv2
      a-to-b:   local:  [gw-a.example.com] uses pre-shared key authentication
      a-to-b:   remote: [gw-b.example.com] uses pre-shared key authentication
      a-to-b:   child:  192.168.10.0/24 === 192.168.20.0/24 TUNNEL
Routed Connections:
      a-to-b{1}:  ROUTED, TUNNEL, reqid 1
Security Associations (1 up, 0 connecting):
      a-to-b[1]: ESTABLISHED 2 seconds ago, 198.51.100.10[gw-a.example.com]...198.51.100.20[gw-b.example.com]
```

5. Compará los dos front-ends contra un mismo demonio compartido:

```bash
sudo ipsec status
sudo swanctl --list-sas     # same charon, different control interface
sudo ipsec up a-to-b
sudo ipsec down a-to-b
```

6. Ajustá el demonio en sí. `/etc/strongswan.conf` es la configuración *del demonio* — no describe conexiones:

```bash
sudo tee /etc/strongswan.conf <<'EOF'
charon {
    load_modular = yes
    install_routes = yes
    install_virtual_ip = yes
    retransmit_tries = 5
    retransmit_timeout = 4.0
    plugins {
        include strongswan.d/charon/*.conf
    }
    filelog {
        stderr {
            default = 1
            ike = 2
            knl = 2
        }
    }
}
include strongswan.d/*.conf
EOF
sudo ipsec restart
```

Inspeccioná el árbol modular de plugins que trae ese `include`:

```bash
ls /etc/strongswan.d/charon/ | head
cat /etc/strongswan.d/charon/kernel-netlink.conf
```

7. **Conocimiento de L2TP/IPsec.** L2TP transporta PPP; no provee cifrado *propio*, así que se envuelve en una SA IPsec en **modo transporte** que protege UDP/1701. Estudiá las dos mitades sin necesariamente desplegarlas.

La mitad IPsec (IKEv1 para clientes legacy de Windows/macOS/Android), como child de `swanctl`:

```conf
connections {
    l2tp-rw {
        version      = 1
        local_addrs  = 198.51.100.10
        remote_addrs = %any
        local  { auth = psk; id = 198.51.100.10 }
        remote { auth = psk }
        children {
            l2tp {
                local_ts      = 198.51.100.10[udp/l2tp]
                remote_ts     = dynamic[udp/%any]
                mode          = transport
                esp_proposals = aes256-sha256,aes128-sha1
            }
        }
        proposals = aes256-sha256-modp2048,aes128-sha1-modp1024
    }
}
```

La mitad L2TP, `/etc/xl2tpd/xl2tpd.conf`:

```ini
[global]
port = 1701
access control = no

[lns default]
ip range = 10.9.0.10-10.9.0.100
local ip = 10.9.0.1
require chap = yes
refuse pap = yes
require authentication = yes
name = LNS-gw-a
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
```

`/etc/ppp/options.xl2tpd`:

```
ipcp-accept-local
ipcp-accept-remote
ms-dns 192.168.10.1
noccp
auth
mtu 1400
mru 1400
lcp-echo-failure 5
lcp-echo-interval 30
connect-delay 5000
```

8. Confirmá que el selector de modo transporte lleva un puerto, cosa que el de modo túnel no tenía:

```bash
sudo ip xfrm policy | grep -A2 'sport 1701\|dport 1701'
```

```
src 198.51.100.10/32 dst 0.0.0.0/0 proto udp sport 1701
	dir out priority 367231 ptype main
	tmpl src 0.0.0.0 dst 0.0.0.0
		proto esp reqid 3 mode transport
```

9. Observá el NAT traversal. Desde un cliente detrás de NAT, los paquetes ESP van encapsulados en UDP/4500:

```bash
sudo tcpdump -n -i eth0 -c 4 'udp port 4500'
sudo ip xfrm state | grep -A1 encap
```

```
	encap type espinudp sport 4500 dport 4500 addr 0.0.0.0
```

### Preguntas de control — Ejercicio 7

36. `ipsec.conf` y `swanctl.conf` produjeron el mismo túnel. Nombrá el proceso con el que habla cada uno, el mecanismo de IPC que usa cada uno, y enunciá el estado actual del camino legacy en upstream.
37. `/etc/ipsec.conf` y `/etc/strongswan.conf` son archivos distintos con nombres solapados. Enunciá qué configura cada uno, y decí cuál editarías para cambiar el comportamiento de retransmisión frente a cuál para cambiar un selector de tráfico.
38. El signo de exclamación en `ike = aes256-sha256-modp3072!` no es decoración. ¿Qué cambia, y cuál es el argumento de seguridad para usarlo?
39. En `ipsec.conf`, `left` y `right` no son "nosotros" y "ellos". Enunciá la regla real que usa strongSwan para decidir qué lado es local, y explicá por qué eso hace que el mismo archivo sea copiable a ambos peers.
40. L2TP no aporta confidencialidad. Dado eso, nombrá las dos cosas que L2TP/IPsec provee y que una SA IPsec pelada en modo transporte no, y explicá por qué la mitad IPsec usa modo transporte y no túnel.
41. `ip xfrm state` muestra `encap type espinudp sport 4500 dport 4500`. Explicá el problema de NAT que esto resuelve, y específicamente por qué ESP puro no puede atravesar un dispositivo NAT que hace traducción de puertos.
42. `uniqueids = yes` está puesto en `config setup`. Describí su efecto cuando el mismo certificado o ID se conecta dos veces, y dá un escenario donde lo pondrías en `no` y otro donde lo pondrías en `replace`.

---

## Ejercicio 8 — Diagnóstico comparativo bajo fallos

**Objetivo:** construir el reflejo de elegir la herramienta correcta para la capa que está rota.

### Pasos

1. Establecé ambas VPNs simultáneamente (OpenVPN desde `rw1`, IPsec `gw-a`↔`gw-b`) y registrá una línea de base sana:

```bash
sudo swanctl --list-sas --raw | wc -l
sudo cat /run/openvpn-server/status-server.log | grep -c '^CLIENT_LIST'
sudo ip xfrm state | grep -c 'proto esp'
```

2. **Inyección A — ESP bloqueado, IKE permitido.** En `gw-b`:

```bash
sudo nft add rule inet vpn input meta l4proto esp drop
sudo swanctl --terminate --ike a-to-b ; sudo swanctl --initiate --child net-net
```

Observá: `swanctl --list-sas` reporta `ESTABLISHED` e `INSTALLED`, los contadores `in` se quedan en 0 y los pings fallan. Confirmalo:

```bash
sudo swanctl --list-sas | grep -E 'in |out '
```

```
    in  c1a2b3c4,      0 bytes,     0 packets
    out d4e5f6a7,    504 bytes,     6 packets,     1s ago
```

Quitá la regla.

3. **Inyección B — desfase de reloj.** En `rw1`:

```bash
sudo timedatectl set-ntp false
sudo date -s '2029-01-01 00:00:00'
sudo openvpn --config /etc/openvpn/client/roadwarrior1.conf --verb 3
```

```
VERIFY ERROR: depth=0, error=certificate has expired: CN=gw-a.example.com
TLS_ERROR: BIO read tls_read_plaintext error
```

Restaurá: `sudo timedatectl set-ntp true`.

4. **Inyección C — MTU asimétrica.** En `gw-a`:

```bash
sudo ip link set dev eth0 mtu 1400
```

Desde `rw1`, los pings chicos a través del túnel OpenVPN funcionan, pero `ssh` y `curl` de páginas grandes se cuelgan. Confirmá la firma y después arreglalo como corresponde:

```bash
ping -c2 192.168.10.50                       # OK
curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 http://192.168.10.50/  # hangs
# server-side remedy
echo 'mssfix 1300 mtu' | sudo tee -a /etc/openvpn/server/server.conf
sudo systemctl restart openvpn-server@server
# and for the IPsec path
sudo nft add rule inet vpn forward tcp flags syn tcp option maxseg size set rt mtu
```

Después restaurá la MTU a 1500.

5. **Inyección D — selectores solapados.** En `gw-b`, cambiá `local_ts` a `192.168.0.0/16`, recargá e iniciá desde `gw-a`:

```
received TS_UNACCEPTABLE notify, no CHILD_SA built
```

Restaurá.

6. Armá la tabla de decisión para vos mismo y completá la columna del medio a partir de los ejercicios anteriores:

| Síntoma | Primer comando | Capa |
|---|---|---|
| `swanctl --list-sas` vacío | | IKE |
| SA `INSTALLED`, contador `in` en 0 | | ESP / firewall |
| OpenVPN: `TLS key negotiation failed` | | canal de control |
| OpenVPN: `AUTH_FAILED` | | autenticación |
| El ping funciona, TCP se cuelga | | MTU / PMTUD |
| `TS_UNACCEPTABLE` | | selectores de tráfico |
| `NO_PROPOSAL_CHOSEN` | | negociación criptográfica |

### Preguntas de control — Ejercicio 8

43. En la Inyección A, `swanctl` reportó la SA como sana mientras el túnel no transportaba nada en un sentido. Explicá por qué el demonio no puede detectar esto por sí solo, y nombrá el único ajuste de configuración que *sí* lo habría detectado — y cuánto tardaría.
44. La Inyección B produjo un error de certificado en el *cliente* aunque nada cambió en el servidor. Más allá de las ventanas de validez de los certificados, nombrá otro elemento sensible al tiempo en cada pila (OpenVPN e IPsec) que un reloj desfasado rompe.
45. Inyección C: explicá por qué `ping` funcionó y `curl` se colgó, por qué el fallo apareció recién al reducir la MTU de *tránsito* y no la del túnel, y por qué el clamp de MSS con `nft` ayuda al camino IPsec pero no a una aplicación basada en UDP sobre él.
46. La Inyección D devolvió `TS_UNACCEPTABLE` y no `NO_PROPOSAL_CHOSEN`. Dado el intercambio en el que se envía cada uno, ¿qué te dice recibir `TS_UNACCEPTABLE` sobre el estado de la autenticación en ese momento?
47. Enunciá dos razones estructurales por las que un operador podría elegir OpenVPN antes que strongSwan para un despliegue de road warriors, y dos razones para elegir IPsec para un enlace site-to-site — usando evidencia que realmente observaste en estos ejercicios.

---

## Respuestas

<details>
<summary><strong>Hacé clic para desplegar las respuestas a las 47 preguntas</strong></summary>

### Ejercicio 1 — PKI

**1.** `EASYRSA_ALGO ec` selecciona claves ECDSA, y OpenVPN entonces negocia **ECDHE** para perfect forward secrecy, que no necesita ningún archivo de parámetros precalculados — de ahí que `dh none` sea aceptable y `gen-dh` innecesario. Todavía necesitás `./easyrsa gen-dh` cuando el certificado de servidor es RSA y querés (o el peer solo soporta) intercambio de claves `DHE` de campo finito, o cuando corrés peers de la época de OpenVPN 2.3 que no implementan ECDHE.

**2.** Sin verificación de EKU, cualquier poseedor de un certificado firmado por tu CA — incluido todo *cliente* legítimo — puede hacerse pasar por el *servidor*. Un cliente malicioso o comprometido levanta un endpoint OpenVPN falso, presenta su propio certificado de cliente válido, y otros clientes lo aceptan: un man-in-the-middle completo dentro de tu propio dominio de confianza. `remote-cert-tls server` en el cliente exige `extendedKeyUsage = serverAuth` más el `keyUsage` correspondiente; el `remote-cert-tls client` del servidor impone el espejo. El equivalente obsoleto era `ns-cert-type server`.

**3.** `tc.key` protege el **canal de control TLS**, no el canal de datos. Con `tls-crypt`, cada paquete del canal de control — incluido el primerísimo del handshake — se cifra *y* autentica con esta clave precompartida antes de que exista la sesión TLS. Un atacante sin ella ve datagramas UDP hacia el puerto 1194 con payloads de alta entropía, y no puede identificarlos como OpenVPN, no puede ver los certificados intercambiados, ni puede provocar respuesta alguna del servidor.

**4.** Con `user nobody`, OpenVPN baja privilegios después de la inicialización, pero **relee `crl.pem` en cada conexión entrante** (desde 2.4). Si el archivo es `0600 root:root`, el demonio en ejecución ya no puede abrirlo. El modo `0644` (con todos los directorios padre atravesables por otros) lo mantiene legible. Una CRL es dato público por diseño — no contiene secretos.

**5.** El día 181 la CRL está vencida, y OpenVPN trata una CRL vencida como un fallo duro: **cada** cliente es rechazado con `VERIFY ERROR: depth=0, error=CRL has expired`. Las listas de revocación deben regenerarse y redistribuirse con una periodicidad menor que `EASYRSA_CRL_DAYS`; esta es una de las caídas totales autoinfligidas más comunes en despliegues de OpenVPN.

### Ejercicio 2 — Servidor enrutado

**6.** Con `topology net30` el servidor toma `10.8.0.1` emparejado con `10.8.0.2`, y el primer cliente obtiene `10.8.0.6` emparejado con `10.8.0.5` — una /30 separada por cliente, consumiendo cuatro direcciones cada uno. Existe porque los drivers TAP-Win32 de Windows históricamente no podían representar una subred sobre una interfaz punto a punto. `topology subnet` es la elección moderna correcta: una dirección por cliente, `/24` en la interfaz, y debe coincidir en ambos extremos (el servidor empuja `topology subnet` en el `PUSH_REPLY`).

**7.** `route` agrega `192.168.20.0/24 dev tun0 scope link` a la **tabla de rutas del kernel del propio servidor**, de modo que el host sabe que debe entregar esos paquetes al proceso OpenVPN. **No** le dijo a la tabla de rutas de clientes *interna* de OpenVPN qué cliente conectado es dueño de esa subred — eso requiere `iroute` en un archivo `ccd` (Ejercicio 4) — y no le informó la ruta a ningún otro cliente VPN, lo cual requiere `push "route ..."`. Las tres son necesarias para el caso site-to-site.

**8.** OpenVPN realiza primero las operaciones privilegiadas — bindea UDP/1194, abre `/dev/net/tun`, crea `tun0`, instala rutas — y recién después llama a `setgid`/`setuid`. El log confirma el orden: `net_iface_up` precede a `GID set to nogroup`. `persist-tun` mantiene abierto el dispositivo tun a través de un reinicio por `SIGUSR1` para que no haya que recrearlo (cosa que el proceso sin privilegios no podría hacer); `persist-key` mantiene los archivos de clave en memoria para que no haya que releerlos del disco (cosa que al proceso sin privilegios podría ya no estarle permitida). Sin ambas, un `--ping-restart` desemboca en un fallo permanente.

**9.** `data-ciphers AES-256-GCM:CHACHA20-POLY1305` es una *lista negociada*; un cliente 2.4 que no puede hacer NCG cae a través de `data-ciphers-fallback` o del valor legacy de `--cipher`. Es una decisión de seguridad porque el cipher de fallback se usa **sin autenticación por negociación** — es lo que diga la configuración, típicamente AES-256-CBC con un HMAC separado, que carece de AEAD y está sujeto a riesgos de la clase padding-oracle que GCM elimina. En OpenVPN 2.6, omitir `data-ciphers-fallback` significa que los clientes que no negocian son simplemente rechazados, que es el default seguro.

**10.** `explicit-exit-notify` hace que el peer envíe un mensaje `OCC_EXIT` explícito al apagarse, de modo que el otro lado derriba la sesión de inmediato en vez de esperar el `ping-restart` (60 s acá). Carece de sentido sobre TCP porque TCP ya señaliza la terminación con FIN/RST, así que el peer se entera de la desconexión por el propio transporte. OpenVPN rechaza la directiva en una instancia TCP.

### Ejercicio 3 — Cliente y diagnóstico

**11.**
- `VERIFY OK: depth=1` — validación de la cadena de la CA, solicitada por `ca` (siempre se realiza).
- `VERIFY KU OK` — chequeo de `keyUsage`, por `remote-cert-tls server`.
- `VERIFY EKU OK` — `extendedKeyUsage = serverAuth`, por `remote-cert-tls server`.
- `VERIFY X509NAME OK` — por `verify-x509-name gw-a.example.com name`.

Si quitás `remote-cert-tls server`, las líneas de KU/EKU desaparecen; la validación de cadena y el chequeo X509NAME siguen disparándose. Notá que `verify-x509-name` por sí sola *no* es un sustituto: un atacante que consiga un certificado con ese CN de la misma CA igual lo pasa.

**12.** Un cliente que confía en el `PUSH_REPLY` está permitiendo que el servidor reescriba su tabla de rutas, sus resolvers DNS y (con `redirect-gateway`) su ruta por defecto. Un servidor comprometido o suplantado puede así secuestrar todo el tráfico y el DNS del cliente. `pull-filter ignore "..."` (o `pull-filter accept`/`reject`) restringe qué opciones empujadas se honran — por ejemplo `pull-filter ignore "dhcp-option DNS"` o `pull-filter ignore "redirect-gateway"`. `route-nopull` deshabilita por completo las rutas empujadas.

**13.** 64 bytes de payload ICMP + 8 de cabecera ICMP + 20 de cabecera IP = 92 bytes de paquete interno; AES-256-GCM agrega un packet ID/opcode de 4 bytes, un tag de autenticación de 16 bytes y el byte de peer-id, quedando en 105. Un observador igual aprende los endpoints de origen/destino, el timing de los paquetes, sus tamaños y el volumen total — suficiente para distinguir SSH interactivo de transferencia masiva o de video, y muchas veces suficiente para identificar el servicio visitado mediante análisis de patrones de tráfico. El cifrado protege el contenido, no los metadatos.

**14.** `-M do` activa el bit Don't-Fragment; la pila local compara 1450 + 28 = 1478 contra la MTU de `tun0` de 1500 menos lo que consumirá la propia encapsulación de OpenVPN, y rechaza la escritura localmente en vez de emitir un paquete no fragmentable. `mssfix` es el arreglo: reescribe la **opción TCP MSS en los paquetes SYN** que atraviesan el túnel para que ambos extremos TCP negocien un tamaño de segmento que entre. No hace nada para UDP porque UDP no tiene negociación de MSS — una aplicación UDP debe descubrir la MTU del camino por sí misma o ser informada, que es exactamente por qué DNS-over-QUIC, WireGuard dentro de OpenVPN y los protocolos UDP de payload grande se rompen de maneras en que TCP no.

**15.** `tls-crypt` cifra y aplica HMAC al primer paquete de control del cliente con la `tc.key` precompartida. El servidor calcula el HMAC sobre el paquete recibido, obtiene un desajuste, y **descarta el paquete antes de asignar estado alguno o escribir cualquier entrada de log en la verbosidad por defecto** — no hay sesión TLS, no hay parseo de certificado, no hay nada que registrar. Beneficio: el servidor es invisible para escáneres de puertos e inmune a DoS de capa TLS desde peers no autenticados, y ninguna CVE de OpenVPN en el camino de parseo TLS es alcanzable sin la clave. Costo: un cliente con la `tc.key` equivocada o faltante no obtiene ningún diagnóstico del lado del servidor — hay que subir `verb` a 6+ en el servidor o capturar paquetes para ver algo.

**16.** `tls-auth` provee **solo autenticación** HMAC: el canal de control está firmado pero sigue siendo legible, así que un observador puede fingerprintear OpenVPN y leer el intercambio de certificados. `tls-crypt` provee autenticación **y cifrado** del canal de control, ocultando los certificados y volviendo el protocolo no identificable. Segunda diferencia: `tls-auth` requiere que la `key-direction` (0/1) sea opuesta en los dos peers; `tls-crypt` deriva claves direccionales por sí mismo y no necesita ese parámetro. `tls-crypt-v2` agrega **claves por cliente**: cada cliente recibe una clave envuelta única que el servidor puede desenvolver con una clave de servidor portadora de metadatos, de modo que una clave de cliente filtrada no compromete la privacidad del canal de control de toda la flota, y los clientes pueden bloquearse individualmente vía `tls-crypt-v2-verify`.

### Ejercicio 4 — CCD, iroute, revocación

**17.**
- `route 192.168.20.0 255.255.255.0` (configuración del servidor) → la **tabla de rutas del kernel del host servidor**: "mandá estos paquetes hacia `tun0`."
- `push "route ..."` → la tabla de rutas del kernel **del cliente**, entregada en el `PUSH_REPLY`.
- `iroute 192.168.20.0 255.255.255.0` (ccd) → la **tabla de rutas de clientes interna** de OpenVPN: "este cliente conectado en particular es dueño de esa subred."

Si omitís solamente el `iroute`, el paquete llega al proceso OpenVPN (la ruta del kernel existe) pero el demonio no tiene idea a cuál de sus clientes entregárselo, así que lo descarta. El log no muestra nada con `verb 3`; con `verb 6` ves mensajes de la clase `MULTI: bad source address from client` o descartes silenciosos.

**18.** Si el archivo ccd no existe, OpenVPN simplemente usa los valores por defecto — el cliente recibe una dirección del pool y ninguna opción por cliente, en silencio. `ccd-exclusive` en la configuración del servidor convierte eso en un rechazo duro: solo pueden conectarse los clientes con un archivo ccd correspondiente. Esta es también la forma correcta de construir un modelo de autorización de certificado-más-lista-blanca.

**19.** OpenVPN relee `crl.pem` **en cada intento de conexión entrante de un cliente** (comportamiento desde 2.4; las versiones anteriores lo cacheaban al arrancar y hacía falta un reinicio). Con `chroot /var/lib/openvpn`, la raíz del sistema de archivos del demonio cambia después de la inicialización, así que una ruta como `/etc/openvpn/server/crl.pem` se vuelve inalcanzable en la segunda lectura y en todas las siguientes. El archivo de CRL debe colocarse *dentro* del chroot y la ruta expresarse relativa a él.

**20.** El demonio sigue corriendo y sigue aceptando clientes — incluidos los revocados. Según la versión y la verbosidad, obtenés una advertencia por conexión (`CRL: cannot read CRL from file`) que se pierde entre el resto del log, o nada en absoluto. Es peor que un crash porque el control de seguridad desapareció en silencio mientras cada dashboard muestra un servicio sano; un crash habría despertado a alguien.

**21.** `kill <CN>` termina la sesión actual, pero el certificado del cliente sigue siendo válido y su configuración `resolv-retry infinite` / `persist-tun` hace que se reconecte en segundos. La interfaz de management es una herramienta operativa, no un control de autorización. Los remedios duraderos son `./easyrsa revoke` + `gen-crl` + `crl-verify` (criptográfico), o `ccd-exclusive` más la eliminación del archivo ccd (basado en configuración), o un script `tls-verify`/`auth-user-pass-verify` que consulte una lista de denegación externa.

**22.** `verify-x509-name gw-a.example.com name` **sí** lo detiene, siempre que el certificado robado tenga un CN distinto — el cliente exige el subject name exacto. `remote-cert-tls server` **también** lo detiene, y de forma más robusta: el certificado robado es un certificado de *cliente* que lleva `extendedKeyUsage = clientAuth`, así que falla el chequeo de EKU sin importar su CN. Ambas son complementarias — la verificación de EKU es estructural (un cert de cliente nunca puede actuar como servidor), la verificación de nombre es específica (fija una identidad). Usá las dos.

### Ejercicio 5 — Site-to-site con IKEv2

**23.** `start_action = trap` instala una **trap policy**: el kernel recibe una política XFRM con SPI 0 cuya `action` es señalizar al espacio de usuario cuando aparezca un paquete coincidente. El primer paquete de 192.168.10.0/24 hacia 192.168.20.0/24 dispara un mensaje ACQUIRE hacia charon, que entonces ejecuta IKE_SA_INIT/IKE_AUTH, negocia la CHILD SA y reemplaza la trap por SAs reales. Hasta entonces `ip xfrm state` está legítimamente vacío — hay una política pero ninguna asociación de seguridad. Los paquetes que disparan el acquire típicamente se descartan o se retienen brevemente, y por eso el primer ping de un túnel `trap` suele mostrar un paquete perdido.

**24.** `dir out`, `dir in`, `dir fwd`. La política `fwd` se requiere específicamente porque este host es un **gateway**: aplica a los paquetes descifrados que llegan del túnel y luego son *reenviados* hacia otra interfaz (hacia la LAN), a diferencia de `in`, que cubre los paquetes destinados al propio host local. Un endpoint puro host-to-host solo necesita `in` y `out`.

**25.** La **IKE SA** es la asociación del plano de control: autentica a los peers y transporta la negociación cifrada de todo lo demás. Cada IKE SA puede transportar muchas **CHILD SAs**, que son las asociaciones ESP reales del plano de datos, un par por cada conjunto de selectores de tráfico protegido. Cada CHILD SA es unidireccional en el kernel, así que siempre hay dos — entrante y saliente — cada una identificada por un **SPI** de 32 bits. Fundamentalmente, **cada lado elige el SPI de la SA por la que va a *recibir***, y se lo comunica al peer; el peer lo pone en los paquetes salientes. Por eso los SPIs `in` y `out` difieren, y por eso el SPI `out` de `gw-a` es igual al SPI `in` de `gw-b`.

**26.** IPsec con XFRM del kernel es una *política* aplicada a los paquetes sobre la interfaz existente; no hay dispositivo virtual. Consecuencias: **(a) filtrado** — no podés escribir reglas `iifname "ipsec0"`; tenés que matchear sobre las direcciones internas en la cadena `forward` más `meta ipsec exists` / estado de `ct`, o usar interfaces `xfrm` (`ip link add ipsec0 type xfrm if_id 42`), que strongSwan soporta vía `if_id_in`/`if_id_out`. **(b) monitoreo** — no hay contador de interfaz por túnel para herramientas que consultan `/proc/net/dev` o la `ifTable` de SNMP; en su lugar hay que leer `ip -s xfrm state` o `swanctl --list-sas`, cosa que muchas plataformas de NMS no hacen de fábrica.

**27.** Sin la regla `accept`, un paquete de 192.168.10.50 hacia 192.168.20.50 atraviesa `forward`, después impacta la regla de masquerade en `postrouting` (que matchea `oifname eth1` o un match de origen amplio) y su dirección de origen es reescrita a la del propio gateway. La política XFRM saliente matchea sobre `src 192.168.10.0/24` — que ya no se cumple — así que el paquete sale **en claro** por `eth0` en vez de ser cifrado. El reporte del operador es "el túnel está arriba pero las LANs no se alcanzan", con `swanctl --list-sas` mostrando cero paquetes en ambas direcciones.

**28.** `start_action = start` inicia la CHILD SA inmediatamente al cargar y la mantiene arriba; `trap` instala una política e inicia solo cuando aparece tráfico coincidente. **(a)** Una sucursal que debe ser alcanzable *desde* la casa central necesita `start` — con `trap`, el tráfico originado en la central llega al lado de la sucursal que no tiene trap y no hay nada que dispare el túnel desde el extremo de la sucursal; las traps unidireccionales producen el "solo funciona después de que alguien en la sucursal hace un ping primero". **(b)** Un enlace LTE de respaldo con tarifa medida debería usar `trap`, para que no se facture tráfico de keepalive ni de rekey mientras el enlace está ocioso.

**29.** MOBIKE (RFC 4555, **solo IKEv2**) permite que una IKE SA establecida y sus CHILD SAs sobrevivan a un cambio de la dirección IP o la interfaz del peer — el peer envía un `UPDATE_SA_ADDRESSES` y las SAs se reanclan sin volver a autenticar. Es irrelevante para un túnel site-to-site fijo porque ninguna de las direcciones de los extremos cambia jamás, y deshabilitarlo elimina superficie de ataque innecesaria. Es esencial para una laptop que va de Ethernet a Wi-Fi a LTE: sin MOBIKE, cada cambio de red fuerza una renegociación IKE completa y tira abajo cada sesión TCP.

### Ejercicio 6 — Certificados y modo transporte

**30.** En **modo túnel** el paquete IP original completo se encapsula y se construye una **nueva cabecera IP externa** con las direcciones de los gateways como origen y destino; el kernel debe conocer esas direcciones de antemano, así que aparecen literalmente en el template. En **modo transporte** la cabecera IP original se *conserva* y solo se protege el payload — no hay una nueva cabecera externa que construir, así que las direcciones del template son `0.0.0.0` (que significa "usá las direcciones del propio paquete"). Esta es también la razón por la que el modo transporte solo funciona cuando los endpoints IPsec son los propios hosts que se comunican.

**31.** El modo transporte preserva la cabecera IP original, así que las direcciones en el cable son las de los *hosts* (192.168.10.50 → 192.168.20.50) — direcciones privadas que la red de tránsito no puede enrutar, y que no identifican a los gateways que poseen la SA. No hay cabecera externa que lleve el paquete entre 198.51.100.10 y 198.51.100.20. Unir dos redes requiere fundamentalmente encapsulación, de ahí el modo túnel.

**32.** `ikeIntermediate` fija una extensión específica de strongSwan al estilo `nsCertType` usada por peers **IKEv1** que requieren que el certificado esté marcado como apto para IKE. **No es necesaria para IKEv2** y es inocua; se incluye en muchos ejemplos por compatibilidad hacia atrás con implementaciones interoperantes más viejas. Los flags relevantes para IKEv2 son `serverAuth`/`clientAuth` (o ninguno — IKEv2 no exige EKU).

**33.** `/etc/swanctl/x509ca` debe contener el **certificado de la CA** — eso es lo que valida el certificado del peer remoto. El certificado propio del peer remoto no necesita estar presente localmente porque IKEv2 lo transmite en el payload `CERT` durante `IKE_AUTH`; el lado local valida el certificado recibido contra la cadena de CA confiable y después lo contrasta con el `remote.id` configurado. Precolocar el certificado del peer en `/etc/swanctl/x509` solo es necesario cuando el peer no lo envía, o cuando querés fijarlo (pinning). `/etc/swanctl/x509crl` guarda CRLs; `/etc/swanctl/private` guarda tu propia clave.

**34.** `NO_PROPOSAL_CHOSEN` para la IKE SA llega durante **`IKE_SA_INIT`**, el primer intercambio, sin cifrar y sin autenticar. `AUTHENTICATION_FAILED` llega durante **`IKE_AUTH`**, que va cifrado bajo claves derivadas en `IKE_SA_INIT`. Por lo tanto, un atacante no autenticado puede sondear libremente tu conjunto de propuestas *IKE* y aprender qué algoritmos aceptás, pero no aprende nada sobre tus identidades ni tus credenciales. (En el paso 8 el desajuste estaba en las propuestas *ESP*, así que se reportó dentro del `IKE_AUTH`/`CREATE_CHILD_SA` ya cifrado — visible solo para el peer autenticado.)

**35.** Con `auth = pubkey`, el `id` es la identidad IKE afirmada en el payload `IDi`/`IDr` y debe coincidir con el **subject DN** del certificado o con alguna de sus entradas de **subjectAltName**. Si no coincide, el peer no puede mapear el certificado presentado a ninguna conexión configurada y responde `AUTHENTICATION_FAILED`, con la línea de log `no matching peer config found for '<local id>'...'<remote id>'` — que nombra ambas identidades tal como se vieron, haciendo el desajuste inmediatamente diagnosticable. Una violación de restricción (por ejemplo, el certificado es válido pero el ID no está cubierto por él) registra `constraint check failed`.

### Ejercicio 7 — Herramientas legacy y L2TP

**36.** Ambos hablan con el **mismo demonio `charon`**. `ipsec`/`ipsec.conf` pasa por el proceso `starter`, que parsea `ipsec.conf` y habla el protocolo **stroke** sobre un socket Unix hacia el plugin `stroke` de charon. `swanctl`/`swanctl.conf` habla **VICI** (Versatile IKE Configuration Interface) sobre `/var/run/charon.vici` hacia el plugin `vici` — una API documentada, versionada y respaldada por una biblioteca. En upstream, `starter`/`stroke`/`ipsec.conf` están **deprecados desde strongSwan 5.6 y eliminados en strongSwan 6.0**; `swanctl` es el camino soportado. El examen todavía lista los archivos legacy, así que tenés que poder leerlos.

**37.** `/etc/ipsec.conf` (o `swanctl.conf`) configura **conexiones**: peers, identidades, autenticación, selectores de tráfico, modos, tiempos de vida. `/etc/strongswan.conf` configura el **demonio y sus plugins**: pool de hilos, temporizadores de retransmisión, logging, instalación de rutas, comportamiento de plugins — con `/etc/strongswan.d/*.conf` y `/etc/strongswan.d/charon/*.conf` incluidos de forma modular. El comportamiento de retransmisión (`retransmit_tries`, `retransmit_timeout`) → `strongswan.conf`. Un selector de tráfico (`leftsubnet` / `local_ts`) → `ipsec.conf` / `swanctl.conf`.

**38.** Sin `!`, las propuestas listadas se **agregan al conjunto de defaults incorporado de strongSwan**, así que el demonio también va a aceptar algoritmos que no listaste — incluidos algunos más débiles que siguen presentes en los defaults. Con `!`, la lista es **exclusiva**: solo se propone y se acepta exactamente lo que escribiste. El argumento de seguridad es que la negociación de algoritmos se resuelve en la opción *mutuamente soportada* más fuerte, y un atacante que pueda influir en la propuesta del peer (o un peer mal configurado) hará que, si no, se aterrice silenciosamente en el mínimo común denominador. `!` vuelve la política auditable: lo que dice el archivo es lo que usa el túnel. (En `swanctl.conf` este es el comportamiento por defecto — las propuestas son exclusivas salvo que escribas `default`.)

**39.** strongSwan decide en el momento de la carga: el lado cuya dirección IP (o las direcciones de las interfaces del host) coincide con `left` pasa a ser **local**; si `left` no coincide con nada local, prueba con `right` e intercambia ambos. `%any` y la resolución de nombres participan en esto. Como la decisión se toma por host en tiempo de ejecución, el *mismo* `ipsec.conf` puede copiarse textualmente a ambos peers — una propiedad de diseño deliberada que también explica por qué `leftid`/`rightid` y `leftsubnet`/`rightsubnet` deben escribirse como un par simétrico y no como "el mío"/"el de ellos".

**40.** L2TP/IPsec agrega **(a) autenticación de usuario basada en PPP** (CHAP/MS-CHAPv2 contra una base de usuarios, RADIUS, etc.) por encima de la autenticación de máquina de IPsec, y **(b) asignación de dirección, DNS y rutas al cliente vía IPCP** — una interfaz virtual PPP con una dirección asignada desde un pool, algo que una SA pelada en modo transporte no tiene mecanismo para proveer. La mitad IPsec usa modo **transporte** porque L2TP ya hace la encapsulación: los paquetes a proteger son datagramas UDP/1701 intercambiados entre las dos direcciones reales de los extremos, y agregar encima una cabecera de túnel IPsec sería encapsulación redundante.

**41.** ESP es el protocolo IP 50 — **no tiene números de puerto**. Un dispositivo NAT que hace traducción de puertos no tiene nada que reescribir ni forma de demultiplexar el tráfico de retorno hacia el host interno correcto, así que un segundo cliente detrás del mismo NAT es indistinguible del primero. Peor aún, el chequeo de integridad de ESP cubre campos que el NAT reescribiría. NAT-Traversal (RFC 3948) detecta el NAT durante IKE (mediante los payloads `NAT_DETECTION_SOURCE_IP`/`DESTINATION_IP`), mueve IKE a **UDP/4500**, y envuelve cada paquete ESP en una cabecera UDP/4500 — dándole al dispositivo NAT puertos que traducir. El kernel registra esto como `encap type espinudp`.

**42.** `uniqueids = yes` significa que cuando un peer se autentica con una identidad que ya tiene una IKE SA establecida, la **SA vieja se elimina** — gana la conexión más nueva. Ponelo en `no` cuando una identidad legítimamente sirve a muchas sesiones simultáneas (un certificado de máquina compartido en una flota detrás de NAT, o un par balanceado). Ponelo en `replace` (o `keep`) cuando necesitás la semántica explícita: `replace` elimina la SA vieja solo después de que la nueva se autentica con éxito; `keep` rechaza la conexión *nueva* y preserva la existente — apropiado cuando un cliente inestable, si no, mataría repetidamente una sesión que funciona.

### Ejercicio 8 — Diagnóstico comparativo

**43.** El plano de datos de IPsec vive enteramente en el kernel; charon instala las SAs y después no ve paquetes. No tiene visibilidad de si está llegando ESP entrante salvo que algo lo pregunte. El ajuste que lo detecta es **DPD** — `dpd_delay` / `dpd_timeout` (o `dpdaction`/`dpddelay` en `ipsec.conf`), que envía sondas de liveness `INFORMATIONAL` de IKEv2 y derriba o reinicia la SA cuando quedan sin respuesta. Con `dpd_delay = 30s` y `dpd_timeout = 120s`, la detección lleva hasta unos dos minutos. Notá que las sondas DPD viajan sobre **IKE (UDP/500 o 4500)**, así que en esta inyección específica — donde IKE está permitido y solo ESP está bloqueado — DPD igual tendría éxito y *no* detectaría el problema. Detectar un camino ESP en agujero negro requiere sondeo extremo a extremo del propio tráfico protegido, o mirar el contador de bytes `in`, que es precisamente para lo que existe ese contador.

**44.** OpenVPN: **el timing de la sesión TLS y su renegociación** (`reneg-sec`) y el `notBefore`/`notAfter` de los certificados, más la validez de `Last Update`/`Next Update` de la **CRL** — un reloj adelantado hace que una CRL por lo demás vigente parezca vencida y rechaza a todos los clientes. IPsec: **la validez de los certificados y la frescura de CRL/OCSP** para `auth = pubkey`, y los **tiempos de vida de las SAs** (`rekey_time`, `life_time`) — un desfase grande hace que las SAs se consideren vencidas inmediatamente después de instalarse, produciendo una tormenta de rekeys. En ambas pilas, un NTP correcto es una dependencia dura, no un lujo.

**45.** `ping` envió payloads de 64 bytes, que entran incluso en un camino de 1400 bytes; `curl` disparó un segmento TCP de datos a tamaño completo, dimensionado a partir de la MTU del *túnel* (1500), que después tuvo que cruzar un enlace de tránsito de 1400 bytes tras los ~50 bytes de encapsulación de OpenVPN. El datagrama UDP resultante excedió la MTU del camino con DF activo; el ICMP "fragmentation needed" o no se generó o no se entregó, así que la conexión quedó colgada después del handshake — el clásico agujero negro de PMTUD. Apareció recién cuando se achicó la MTU de *tránsito* porque la MTU del túnel había sido consistente en ambos lados; el desajuste siempre está entre el tamaño del paquete encapsulado y lo que la red subyacente puede transportar. El clamp de MSS con `nft` ayuda al camino IPsec porque reescribe la opción TCP MSS en los paquetes SYN que se reenvían, haciendo que ambos extremos TCP negocien segmentos que entren — pero UDP no tiene MSS que clampear, así que una aplicación UDP sobre IPsec debe arreglarse en la capa de aplicación o bajando la MTU del endpoint.

**46.** `TS_UNACCEPTABLE` se envía en respuesta a una negociación de CHILD SA (`IKE_AUTH` o `CREATE_CHILD_SA`), ambas ocurren **después** de que los peers se autenticaron mutuamente y están intercambiando mensajes cifrados y protegidos en integridad. Recibirlo, por lo tanto, demuestra que la autenticación tuvo éxito: tus credenciales, identidades y propuestas IKE están todas correctas, y el problema es puramente un desajuste de configuración en los selectores de tráfico. Esto es diagnósticamente valioso — elimina toda la superficie de PKI/PSK de la investigación en un solo paso.

**47.** **OpenVPN para road warriors:** (i) corre sobre un único puerto UDP o **TCP** y puede hacerse pasar por tráfico TLS común, así que atraviesa redes restrictivas y NAT sin las contorsiones de NAT-T — viste UDP/1194 plano en la captura, sin ESP y sin requerir el protocolo 50 en el firewall; (ii) presenta una interfaz `tun0` real, así que el filtrado por cliente, el matcheo por interfaz de `iptables`/`nft` y el monitoreo basado en interfaz funcionan con herramientas comunes — y la política por cliente vía `ccd`/`ifconfig-push` no necesitó involucrar al kernel en absoluto. **IPsec para site-to-site:** (i) el cifrado y la encapsulación ocurren en el **kernel**, sin copia al espacio de usuario por paquete y con offload de hardware disponible, así que el throughput en un gateway es materialmente mayor — el túnel del Ejercicio 5 no requirió participación alguna del demonio en el camino de datos; (ii) es un estándar neutral respecto del fabricante, así que `gw-b` podría ser un Cisco, un Juniper, un Fortinet o el gateway VPN de un proveedor de nube, y aplican las mismas semánticas de `swanctl.conf` — mientras que OpenVPN requiere OpenVPN en ambos extremos.

</details>

---

## Fuentes

- LPI, *Exam 303 Objectives (303-300, v3.0.0)* — <https://www.lpi.org/our-certifications/exam-303-objectives/>
- OpenVPN Community, *Reference Manual for OpenVPN 2.6* — <https://openvpn.net/community-resources/reference-manual-for-openvpn-2-6/>
- OpenVPN Community, *HOWTO* — <https://openvpn.net/community-resources/how-to/>
- OpenVPN, *Easy-RSA 3 Documentation* — <https://github.com/OpenVPN/easy-rsa/blob/master/doc/EasyRSA-Advanced.md>
- strongSwan, *swanctl.conf reference* — <https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html>
- strongSwan, *strongswan.conf reference* — <https://docs.strongswan.org/docs/latest/config/strongswanConf.html>
- strongSwan, *Deprecated ipsec.conf / starter* — <https://docs.strongswan.org/docs/latest/config/ipsecConf.html>
- strongSwan, *pki — Public Key Infrastructure tool* — <https://docs.strongswan.org/docs/latest/pki/pki.html>
- strongSwan, *IKEv2 Cipher Suites / proposal syntax* — <https://docs.strongswan.org/docs/latest/config/proposals.html>
- strongSwan, *Forwarding and Split Tunneling* — <https://docs.strongswan.org/docs/latest/howtos/forwarding.html>
- RFC 7296, *Internet Key Exchange Protocol Version 2 (IKEv2)* — <https://www.rfc-editor.org/rfc/rfc7296>
- RFC 4303, *IP Encapsulating Security Payload (ESP)* — <https://www.rfc-editor.org/rfc/rfc4303>
- RFC 3948, *UDP Encapsulation of IPsec ESP Packets* — <https://www.rfc-editor.org/rfc/rfc3948>
- RFC 4555, *IKEv2 Mobility and Multihoming Protocol (MOBIKE)* — <https://www.rfc-editor.org/rfc/rfc4555>
- RFC 3193, *Securing L2TP using IPsec* — <https://www.rfc-editor.org/rfc/rfc3193>
- man-pages project, *ip-xfrm(8)* — <https://man7.org/linux/man-pages/man8/ip-xfrm.8.html>
- xl2tpd, *upstream repository and configuration* — <https://github.com/xelerance/xl2tpd>