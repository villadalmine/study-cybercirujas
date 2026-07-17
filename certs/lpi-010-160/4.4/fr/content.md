# 4.4 Your Computer on the Network

## Pourquoi ce sujet compte

Avant de pouvoir dépanner un réseau, il faut comprendre comment votre machine `Linux` s'y connecte : quelle adresse IP elle porte, comment elle sait où envoyer un paquet, et comment elle résout un nom de domaine en adresse. Ce sujet couvre les bases du *networking* : concepts TCP/IP, configuration réseau côté client, et les commandes essentielles pour observer et diagnostiquer l'état du réseau.

## Concepts de base TCP/IP

`TCP/IP` (Transmission Control Protocol / Internet Protocol) est la suite de protocoles qui fait fonctionner Internet et la plupart des réseaux locaux. Chaque machine connectée possède une **adresse IP**, identifiant unique (dans son réseau) qui permet le routage des paquets.

### IPv4

Une adresse `IPv4` s'écrit sous forme de 4 octets séparés par des points (*dotted decimal notation*), par exemple `192.168.1.42`. Elle est toujours accompagnée d'un **masque de sous-réseau** (*netmask*), qui détermine quelle partie de l'adresse identifie le réseau et quelle partie identifie l'hôte.

- `255.255.255.0` (ou `/24` en notation `CIDR`) : les 24 premiers bits identifient le réseau, les 8 derniers l'hôte → 254 adresses d'hôtes utilisables.
- Exemple : `192.168.1.42/24` appartient au réseau `192.168.1.0`, avec `192.168.1.255` comme adresse de broadcast.

Quelques plages réservées à connaître :
- `127.0.0.0/8` : *loopback*, dont `127.0.0.1` (le fameux **localhost**), qui désigne la machine elle-même.
- `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` : adresses privées (*RFC 1918*), non routables sur Internet, utilisées derrière un `NAT` (*Network Address Translation*).

### IPv6

`IPv6` remplace progressivement IPv4 avec un espace d'adressage bien plus vaste (128 bits vs 32). Une adresse s'écrit en hexadécimal, séparée par `:`, par exemple :

```
2001:0db8:85a3:0000:0000:8a2e:0370:7334
```

Elle peut être abrégée en supprimant les zéros de tête et en remplaçant une séquence de zéros consécutifs par `::` :

```
2001:db8:85a3::8a2e:370:7334
```

L'équivalent du *loopback* IPv4 est `::1`.

### Passerelle et routage

La **passerelle par défaut** (*default gateway*) est l'adresse du routeur vers lequel votre machine envoie les paquets destinés à un réseau qu'elle ne connaît pas directement (typiquement, tout ce qui n'est pas sur son réseau local). Sans passerelle configurée correctement, la machine peut communiquer avec le réseau local mais pas avec Internet.

### DHCP

Le `DHCP` (*Dynamic Host Configuration Protocol*) permet à une machine d'obtenir automatiquement, au démarrage ou à la connexion, son adresse IP, son masque, sa passerelle et ses serveurs DNS auprès d'un serveur DHCP. C'est le mode par défaut sur la plupart des réseaux domestiques et d'entreprise, à l'opposé d'une configuration **statique** (adresse fixée manuellement).

### DNS

Le `DNS` (*Domain Name System*) traduit les noms de domaine lisibles (`example.com`) en adresses IP. Côté client, la configuration DNS se trouve historiquement dans `/etc/resolv.conf` :

```
nameserver 8.8.8.8
nameserver 1.1.1.1
```

Sur les systèmes modernes, cette configuration est souvent gérée dynamiquement par `systemd-resolved` ou `NetworkManager`, qui régénèrent `/etc/resolv.conf` automatiquement.

Le fichier `/etc/hosts` permet de définir des correspondances nom→IP locales, prioritaires sur le DNS pour la résolution :

```
127.0.0.1   localhost
192.168.1.10  fileserver.local fileserver
```

## Commandes essentielles

### Afficher la configuration réseau : `ip`

La commande moderne `ip` (du paquet `iproute2`) remplace l'ancienne `ifconfig`.

```
$ ip addr show
2: enp0s3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 08:00:27:4e:66:a1 brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.42/24 brd 192.168.1.255 scope global dynamic enp0s3
       valid_lft 82734sec preferred_lft 82734sec
    inet6 fe80::a00:27ff:fe4e:66a1/64 scope link
```

On y retrouve l'adresse `MAC` (*link/ether*), l'adresse IPv4 avec son masque en `CIDR`, et l'adresse IPv6 *link-local*.

Version courte, souvent utilisée en interactif :

```
$ ip a
```

Afficher la table de routage :

```
$ ip route show
default via 192.168.1.1 dev enp0s3 proto dhcp metric 100
192.168.1.0/24 dev enp0s3 proto kernel scope link src 192.168.1.42
```

La ligne `default via 192.168.1.1` indique la passerelle par défaut.

### `ifconfig` (historique)

Toujours présente sur beaucoup de systèmes (paquet `net-tools`), bien que dépréciée :

```
$ ifconfig enp0s3
enp0s3: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 192.168.1.42  netmask 255.255.255.0  broadcast 192.168.1.255
        ether 08:00:27:4e:66:a1  txqueuelen 1000  (Ethernet)
```

### Tester la connectivité : `ping`

`ping` envoie des paquets `ICMP Echo Request` et mesure le temps de réponse (*RTT*, round-trip time).

```
$ ping -c 4 192.168.1.1
PING 192.168.1.1 (192.168.1.1) 56(84) bytes of data.
64 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=0.412 ms
64 bytes from 192.168.1.1: icmp_seq=2 ttl=64 time=0.389 ms
64 bytes from 192.168.1.1: icmp_seq=3 ttl=64 time=0.401 ms
64 bytes from 192.168.1.1: icmp_seq=4 ttl=64 time=0.395 ms

--- 192.168.1.1 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3054ms
```

L'option `-c` limite le nombre de paquets (sans elle, `ping` continue indéfiniment sur Linux). Un `ping` réussi vers la passerelle mais échoué vers un serveur externe (`ping 8.8.8.8`) pointe souvent vers un problème de routage vers Internet ; un échec vers une IP externe mais un succès vers un nom de domaine externe est impossible — c'est plutôt l'inverse qui signale un problème `DNS` (l'IP répond, le nom ne se résout pas).

### Tracer le chemin réseau : `traceroute` / `tracepath`

Affiche chaque routeur (*hop*) traversé jusqu'à la destination :

```
$ traceroute example.com
traceroute to example.com (93.184.216.34), 30 hops max, 60 byte packets
 1  192.168.1.1 (192.168.1.1)  0.512 ms  0.478 ms  0.461 ms
 2  10.0.0.1 (10.0.0.1)  8.213 ms  8.190 ms  8.177 ms
 3  * * *
 4  93.184.216.34 (93.184.216.34)  22.401 ms  22.380 ms  22.355 ms
```

Les `*` indiquent un routeur qui ne répond pas (souvent parce qu'il bloque volontairement l'ICMP), pas nécessairement une coupure du chemin.

### Résolution DNS : `host` et `dig`

```
$ host example.com
example.com has address 93.184.216.34
example.com has IPv6 address 2606:2800:220:1:248:1893:25c8:1946

$ dig example.com +short
93.184.216.34
```

`dig` (*Domain Information Groper*) donne un contrôle plus fin (type d'enregistrement, serveur interrogé) que `host`, très utile pour vérifier des enregistrements spécifiques :

```
$ dig example.com MX +short
```

### État des connexions : `ss` (et `netstat`)

`ss` (*socket statistics*) remplace l'ancien `netstat` pour lister les connexions et ports en écoute :

```
$ ss -tulpn
Netid State  Local Address:Port   Peer Address:Port  Process
tcp   LISTEN 0.0.0.0:22           0.0.0.0:*          users:(("sshd",pid=812,fd=3))
tcp   LISTEN 127.0.0.1:631        0.0.0.0:*          users:(("cupsd",pid=934,fd=7))
```

- `-t` : sockets TCP, `-u` : sockets UDP, `-l` : en écoute (*listening*) uniquement, `-p` : afficher le processus, `-n` : ne pas résoudre les noms (affichage numérique, plus rapide).

## Résumé des repères clés

| Élément | Exemple | Rôle |
|---|---|---|
| Adresse IPv4 | `192.168.1.42/24` | Identifie l'hôte sur le réseau |
| Masque / CIDR | `255.255.255.0` = `/24` | Sépare réseau et hôte |
| Passerelle par défaut | `192.168.1.1` | Sortie vers les autres réseaux |
| `127.0.0.1` / `::1` | *localhost* | Boucle locale, la machine elle-même |
| DHCP | automatique | Configuration IP dynamique |
| DNS | `/etc/resolv.conf`, `/etc/hosts` | Résolution nom ↔ IP |

## Références

- LPI Learning Materials — Topic 4.4: Your Computer on the Network : https://learning.lpi.org/en/learning-materials/010-160/4/4.4/
- `ip(8)` man page : https://man7.org/linux/man-pages/man8/ip.8.html
- `ping(8)` man page : https://man7.org/linux/man-pages/man8/ping.8.html
- `dig(1)` man page : https://man7.org/linux/man-pages/man1/dig.1.html
- `ss(8)` man page : https://man7.org/linux/man-pages/man8/ss.8.html
- RFC 1918 — Address Allocation for Private Internets : https://www.rfc-editor.org/rfc/rfc1918