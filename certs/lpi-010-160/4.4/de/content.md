# 4.4 Your Computer on the Network

## Grundlagen des Networking

Damit ein Linux-Rechner mit anderen Systemen kommunizieren kann, braucht er mindestens: eine **IP-Adresse**, eine **Netzmask** (subnet mask), ein **Default Gateway** und einen **DNS-Server** zur Namensauflösung. Diese vier Werte werden entweder manuell (static configuration) oder automatisch über **DHCP** (Dynamic Host Configuration Protocol) bezogen.

Ein Netzwerk-Interface (z. B. `eth0`, `enp0s3`, `wlan0`) ist die logische Schnittstelle, über die der Kernel Pakete sendet und empfängt. Das Loopback-Interface `lo` (Adresse `127.0.0.1`) dient der internen Kommunikation eines Hosts mit sich selbst.

## IP-Adressen und Netzmasken

Eine IPv4-Adresse besteht aus vier Oktetten (z. B. `192.168.1.10`) und wird zusammen mit einer Netzmask oder CIDR-Notation angegeben, die festlegt, welcher Teil der Adresse das Netz und welcher den Host identifiziert.

```bash
$ ip addr show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 08:00:27:4a:3e:11 brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.10/24 brd 192.168.1.255 scope global dynamic eth0
       valid_lft 84234sec preferred_lft 84234sec
    inet6 fe80::a00:27ff:fe4a:3e11/64 scope link
       valid_lft forever preferred_lft forever
```

`/24` entspricht der Netzmask `255.255.255.0` und bedeutet 254 nutzbare Host-Adressen im Netz `192.168.1.0/24`. IPv6-Adressen (128 Bit, hexadezimal, z. B. `fe80::a00:27ff:fe4a:3e11`) werden zunehmend parallel zu IPv4 (Dual Stack) eingesetzt.

Das ältere, aber auf vielen Prüfungen und Systemen noch relevante Kommando `ifconfig` (aus `net-tools`) zeigt ähnliche Informationen:

```bash
$ ifconfig eth0
eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 192.168.1.10  netmask 255.255.255.0  broadcast 192.168.1.255
        ether 08:00:27:4a:3e:11  txqueuelen 1000  (Ethernet)
```

Die **MAC-Adresse** (Media Access Control, hier `08:00:27:4a:3e:11`) identifiziert das Netzwerkinterface eindeutig auf Hardware-Ebene (Layer 2), während die IP-Adresse auf Layer 3 arbeitet.

## Static Configuration vs. DHCP

- **Static IP**: Die Netzwerkeinstellungen (IP, Netmask, Gateway, DNS) werden manuell in Konfigurationsdateien eingetragen (z. B. `/etc/network/interfaces` bei Debian-basierten Systemen oder über `NetworkManager`/`nmcli`). Sinnvoll für Server, die eine konstante Adresse benötigen.
- **DHCP**: Ein DHCP-Server im Netz weist dem Client automatisch eine freie IP-Adresse samt Netmask, Gateway und DNS-Servern zu (Lease-basiert, zeitlich befristet). Das ist der Standard für die meisten Endgeräte (Laptops, Desktops).

```bash
$ nmcli device show eth0 | grep -E "IP4|DHCP"
IP4.ADDRESS[1]:                        192.168.1.10/24
IP4.GATEWAY:                           192.168.1.1
IP4.DNS[1]:                            192.168.1.1
```

## Wichtige Konfigurationsdateien

- `/etc/hosts` – statische Zuordnung von Hostnamen zu IP-Adressen, wird vor DNS geprüft.
- `/etc/resolv.conf` – listet die zu verwendenden DNS-Server (`nameserver`).
- `/etc/nsswitch.conf` – legt die Reihenfolge der Namensauflösung fest (z. B. erst `files`, dann `dns`).
- `/etc/hostname` – enthält den Hostnamen des Systems.

```bash
$ cat /etc/hosts
127.0.0.1   localhost
192.168.1.20 fileserver.local fileserver

$ cat /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
```

## DNS: Hostnamen auflösen

DNS (Domain Name System) übersetzt menschenlesbare Hostnamen (z. B. `example.com`) in IP-Adressen. Die klassischen Tools dafür sind `host`, `dig` und `nslookup`.

```bash
$ host example.com
example.com has address 93.184.216.34

$ dig example.com +short
93.184.216.34

$ nslookup example.com
Server:         8.8.8.8
Address:        8.8.8.8#53

Name:   example.com
Address: 93.184.216.34
```

Den eigenen Hostnamen zeigt `hostname`:

```bash
$ hostname
myworkstation
$ hostname -I
192.168.1.10
```

## Routing

Der Kernel entscheidet anhand der **Routing-Tabelle**, über welches Interface und welches Gateway ein Paket sein Ziel erreicht. Das Default Gateway wird für alle Ziele verwendet, für die keine spezifischere Route existiert.

```bash
$ ip route show
default via 192.168.1.1 dev eth0
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.10
```

Das ältere Äquivalent:

```bash
$ route -n
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         192.168.1.1     0.0.0.0         UG    100    0        0 eth0
192.168.1.0     0.0.0.0         255.255.255.0   U     100    0        0 eth0
```

## Konnektivität prüfen

`ping` sendet ICMP-Echo-Requests, um zu testen, ob ein Host erreichbar ist:

```bash
$ ping -c 3 example.com
PING example.com (93.184.216.34) 56(84) bytes of data.
64 bytes from 93.184.216.34: icmp_seq=1 ttl=56 time=12.3 ms
64 bytes from 93.184.216.34: icmp_seq=2 ttl=56 time=11.9 ms
64 bytes from 93.184.216.34: icmp_seq=3 ttl=56 time=12.1 ms

--- example.com ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
```

`traceroute` (oder `tracepath`, wenn keine Root-Rechte verfügbar sind) zeigt jeden Hop auf dem Weg zum Ziel – nützlich, um zu erkennen, an welcher Stelle eine Verbindung scheitert:

```bash
$ traceroute example.com
 1  192.168.1.1 (192.168.1.1)  1.234 ms
 2  10.0.0.1 (10.0.0.1)  8.532 ms
 3  93.184.216.34 (93.184.216.34)  12.045 ms
```

## Ports und Dienste

Netzwerkdienste sind über **Ports** erreichbar. Bekannte Zuordnungen stehen in `/etc/services`:

```bash
$ grep -E "^(ssh|http|https|ftp)\s" /etc/services
ftp             21/tcp
ssh             22/tcp
http            80/tcp
https           443/tcp
```

Wichtige well-known Ports: `21` (FTP), `22` (SSH), `25` (SMTP), `53` (DNS), `80` (HTTP), `443` (HTTPS).

Mit `ss` (moderner Ersatz für `netstat`) lassen sich aktive Verbindungen und lauschende Ports anzeigen:

```bash
$ ss -tulnp
Netid State  Local Address:Port  Peer Address:Port  Process
tcp   LISTEN 0.0.0.0:22          0.0.0.0:*           users:(("sshd",pid=812,fd=3))
tcp   LISTEN 0.0.0.0:80          0.0.0.0:*           users:(("nginx",pid=901,fd=6))
```

## Client-Server-Modell

Im Client-Server-Modell stellt ein **Server** einen Dienst über einen bestimmten Port bereit (z. B. ein Webserver auf Port 80/443), während der **Client** eine Verbindung zu diesem Port aufbaut, um den Dienst zu nutzen. Ein Linux-System kann gleichzeitig Client (z. B. beim Surfen mit einem Browser) und Server (z. B. als SSH-Server) sein.

## Referenzen

- LPI Learning Materials, Topic 4.4: https://learning.lpi.org/en/learning-materials/010-160/4/4.4/
- `ip` command manual: https://man7.org/linux/man-pages/man8/ip.8.html
- `dig` command manual: https://man7.org/linux/man-pages/man1/dig.1.html
- `ping` command manual: https://man7.org/linux/man-pages/man8/ping.8.html
- `traceroute` command manual: https://man7.org/linux/man-pages/man8/traceroute.8.html
- `resolv.conf` manual: https://man7.org/linux/man-pages/man5/resolv.conf.5.html
- `hosts` manual: https://man7.org/linux/man-pages/man5/hosts.5.html