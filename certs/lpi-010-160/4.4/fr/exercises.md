# Exercices guidés — Thème 4.4 : Your Computer on the Network

*Certification LPI Linux Essentials (010-160, v1.6) — Référence : [learning.lpi.org/en/learning-materials/010-160/4/4.4/](https://learning.lpi.org/en/learning-materials/010-160/4/4.4/)*

---

## Exercice 1 — Identifier la configuration IP de la machine

1. Ouvrez un terminal.
2. Affichez les interfaces réseau et leurs adresses avec la commande moderne :
   ```bash
   ip a
   ```
3. Repérez dans la sortie l'interface active (souvent `eth0`, `enp0s3` ou `wlan0`), son adresse IPv4 au format `adresse/préfixe` (ex. `192.168.1.42/24`), et son adresse `link/ether` (adresse MAC).
4. Comparez avec l'ancienne commande équivalente (paquet `net-tools`, souvent absent par défaut) :
   ```bash
   ifconfig
   ```

> **Question 1** : Que signifie le `/24` accolé à une adresse IPv4 comme `192.168.1.42/24` ?
> **Question 2** : Pourquoi la commande `ip` est-elle aujourd'hui préférée à `ifconfig` sur la plupart des distributions Linux ?

---

## Exercice 2 — Lire la table de routage et trouver la gateway

1. Affichez la table de routage :
   ```bash
   ip route
   ```
2. Identifiez la ligne commençant par `default via ... dev ...` : c'est votre **default gateway**, le routeur utilisé pour tout trafic vers un réseau non local.
3. Notez également la ligne décrivant votre réseau local (ex. `192.168.1.0/24 dev eth0 ... src 192.168.1.42`).
4. Testez l'atteignabilité de la gateway :
   ```bash
   ping -c 4 <adresse_de_la_gateway>
   ```

> **Question 3** : Que se passe-t-il, en principe, quand un paquet est destiné à une adresse hors de votre réseau local et qu'aucune route par défaut n'est configurée ?

---

## Exercice 3 — Résolution DNS

1. Consultez les serveurs DNS configurés sur votre machine :
   ```bash
   cat /etc/resolv.conf
   ```
2. Interrogez un serveur DNS pour résoudre un nom de domaine :
   ```bash
   host www.lpi.org
   ```
3. Faites de même avec `dig` (sortie plus détaillée) :
   ```bash
   dig www.lpi.org
   ```
4. Dans la sortie de `dig`, repérez la section `ANSWER SECTION` et le champ `TTL`.

> **Question 4** : Quel est le rôle du DNS dans le fonctionnement d'Internet ?
> **Question 5** : Que représente le TTL (Time To Live) d'un enregistrement DNS ?

---

## Exercice 4 — Tester la connectivité de bout en bout

1. Vérifiez que la résolution DNS et la connectivité fonctionnent ensemble :
   ```bash
   ping -c 4 www.lpi.org
   ```
2. Tracez le chemin réseau emprunté jusqu'à ce serveur (root ou `sudo` requis selon la distribution) :
   ```bash
   traceroute www.lpi.org
   ```
   ou, si `traceroute` n'est pas disponible :
   ```bash
   tracepath www.lpi.org
   ```
3. Observez le nombre de sauts (hops) et les temps de latence à chaque étape.

> **Question 6** : Quelle différence de fond y a-t-il entre `ping` et `traceroute` dans ce qu'ils permettent de diagnostiquer ?

---

## Exercice 5 — Ports et connexions actives

1. Listez les connexions réseau actives et les ports en écoute avec l'outil moderne :
   ```bash
   ss -tulpn
   ```
   (`-t` TCP, `-u` UDP, `-l` listening, `-p` process, `-n` numérique)
2. Repérez un service courant, par exemple un serveur SSH en écoute sur le port `22`.
3. Comparez avec l'ancienne commande équivalente si disponible :
   ```bash
   netstat -tulpn
   ```

> **Question 7** : Associez chacun des ports suivants à son service standard : `22`, `53`, `80`, `443`.
> **Question 8** : Quelle est la différence entre TCP et UDP du point de vue du transport des données ?

---

## Exercice 6 — Adresses privées, adresses publiques et NAT

1. Reprenez l'adresse IPv4 obtenue à l'exercice 1 (via `ip a`).
2. Déterminez si elle appartient à une des plages d'adresses privées définies par la RFC 1918 :
   - `10.0.0.0/8`
   - `172.16.0.0/12`
   - `192.168.0.0/16`
3. Comparez cette adresse à votre adresse IP publique, visible depuis l'extérieur de votre réseau (par exemple via un service web dédié ou la commande `curl ifconfig.me` si `curl` est installé et l'accès Internet autorisé).

> **Question 9** : Pourquoi une machine peut-elle avoir une adresse privée en interne et une adresse publique différente vue depuis Internet ?
> **Question 10** : Quel mécanisme, généralement implémenté sur le routeur domestique, permet cette traduction d'adresses ?

---

## Exercice 7 — DHCP vs configuration statique

1. Vérifiez si votre interface a obtenu son adresse via DHCP en consultant les logs système :
   ```bash
   journalctl -u NetworkManager --no-pager | grep -i dhcp
   ```
   (le nom du service peut varier selon la distribution, ex. `systemd-networkd`, `dhclient`)
2. Observez la durée de bail (**lease time**) attribuée par le serveur DHCP si l'information est disponible dans les logs ou dans `ip a` (champ `valid_lft`).

> **Question 11** : Citez deux paramètres réseau, en plus de l'adresse IP, qu'un serveur DHCP peut fournir automatiquement à un client.

---

<details>
<summary><strong>Réponses</strong></summary>

**Q1.** Le `/24` est le préfixe CIDR : il indique que les 24 premiers bits de l'adresse (soit les trois premiers octets) désignent la partie réseau, et les 8 bits restants la partie hôte. Cela équivaut à un masque de sous-réseau `255.255.255.0`, offrant 254 adresses d'hôtes utilisables.

**Q2.** `ifconfig` fait partie du paquet historique `net-tools`, qui n'est plus maintenu activement et n'est plus installé par défaut sur de nombreuses distributions récentes. `ip` (du paquet `iproute2`) le remplace : il est activement maintenu, gère aussi bien IPv4 qu'IPv6, et couvre davantage de fonctionnalités (routage, tunnels, etc.) avec une syntaxe unifiée.

**Q3.** Le paquet ne peut pas être acheminé en dehors du réseau local : le système ne sait pas vers quel routeur l'envoyer, la connexion échoue (généralement avec une erreur de type "network unreachable" ou un timeout).

**Q4.** Le DNS (Domain Name System) traduit les noms de domaine lisibles par un humain (ex. `www.lpi.org`) en adresses IP utilisables par les machines pour établir une connexion réseau.

**Q5.** Le TTL indique, en secondes, pendant combien de temps un enregistrement DNS peut être mis en cache par un résolveur avant qu'il ne doive être interrogé à nouveau auprès du serveur faisant autorité.

**Q6.** `ping` vérifie uniquement si une machine distante est joignable et mesure le temps d'aller-retour (RTT), sans indiquer le chemin emprunté. `traceroute` révèle chaque routeur intermédiaire (hop) traversé jusqu'à la destination, ce qui permet de localiser où un problème de connectivité ou de latence se produit sur le trajet.

**Q7.**
- `22` → SSH (Secure Shell)
- `53` → DNS
- `80` → HTTP
- `443` → HTTPS

**Q8.** TCP est un protocole orienté connexion, fiable : il garantit l'ordre et la livraison des données via accusés de réception et retransmissions. UDP est sans connexion et sans garantie de livraison ni d'ordre, mais plus léger et rapide, adapté aux usages tolérant la perte de paquets (streaming, DNS, VoIP).

**Q9.** L'adresse privée n'est valable qu'à l'intérieur du réseau local (LAN) et n'est pas routable sur Internet. Le routeur qui relie ce réseau local à Internet possède, lui, une adresse publique unique et routable ; c'est cette dernière qui est visible depuis l'extérieur pour toutes les machines du LAN.

**Q10.** Le NAT (Network Address Translation), généralement sous sa variante PAT/masquerade, traduit les adresses privées internes en l'unique adresse publique du routeur (en associant les numéros de port) pour permettre à plusieurs machines du LAN de partager une seule adresse publique.

**Q11.** Par exemple : l'adresse du default gateway, l'adresse des serveurs DNS, le masque de sous-réseau (netmask), et la durée du bail (lease time) elle-même.

</details>