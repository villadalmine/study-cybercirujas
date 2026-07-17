# Übung: Your Computer on the Network (Thema 4.4)

**Quelle (Referenz):** https://learning.lpi.org/en/learning-materials/010-160/4/4.4/

In dieser Übung untersuchst du, wie dein Linux-Rechner mit einem Netzwerk verbunden ist: welche IP address er hat, wie DNS resolution funktioniert, ob andere Hosts erreichbar sind und welche Ports/connections gerade aktiv sind. Führe die Befehle in einem Terminal aus (falls nötig mit `sudo`).

---

## Teil 1: Die eigene Netzwerkkonfiguration anzeigen

1. Zeige den Hostname deines Rechners an:
   ```
   hostname
   ```
2. Liste alle network interfaces und ihre IP addresses auf:
   ```
   ip addr show
   ```
   Achte auf Interfaces wie `lo` (loopback), `eth0`/`enp*s0` (kabelgebunden) oder `wlan0`/`wlp*s0` (WLAN).
3. Zeige die default gateway und die routing table an:
   ```
   ip route show
   ```
4. Prüfe, ob dein Rechner die IP address per DHCP bezogen hat oder ob eine static IP address konfiguriert ist. Ein Hinweis dazu findet sich oft in der Ausgabe von:
   ```
   ip addr show
   ```
   (Suche nach `dynamic` im Output der jeweiligen Adresse.)

**Verständnisfragen:**
- Was ist der Unterschied zwischen der `lo`-Schnittstelle und einer physischen Schnittstelle wie `eth0`?
- Wofür wird das default gateway benötigt, wenn dein Rechner mit einem Host außerhalb des lokalen Netzwerks kommunizieren will?

---

## Teil 2: DNS resolution testen

1. Löse einen Domainnamen in eine IP address auf:
   ```
   host example.org
   ```
2. Führe dieselbe Abfrage mit einem anderen Tool durch und vergleiche die Ausgabe:
   ```
   dig example.org
   ```
3. Zeige an, welche DNS server dein System für die Namensauflösung verwendet:
   ```
   cat /etc/resolv.conf
   ```
4. Öffne die Datei `/etc/hosts` und sieh dir den Inhalt an:
   ```
   cat /etc/hosts
   ```
   Diese Datei erlaubt eine lokale Namensauflösung, die Vorrang vor DNS haben kann.

**Verständnisfragen:**
- Welche Rolle spielt ein DNS server im Ablauf, wenn du im Browser `example.org` eingibst?
- In welcher Reihenfolge prüft ein typisches Linux-System `/etc/hosts` und den DNS server bei einer Namensauflösung?

---

## Teil 3: Erreichbarkeit von Hosts prüfen

1. Prüfe, ob ein entfernter Host erreichbar ist:
   ```
   ping -c 4 example.org
   ```
   Die Option `-c 4` begrenzt die Anzahl der gesendeten ICMP-Pakete auf 4.
2. Verfolge den Weg (die einzelnen hops), den die Pakete zu diesem Host nehmen:
   ```
   traceroute example.org
   ```
   (Falls nicht installiert, alternativ: `tracepath example.org`)
3. Vergleiche die Round-Trip-Zeiten (RTT) aus Schritt 1 mit den Zeiten der einzelnen hops aus Schritt 2.

**Verständnisfragen:**
- Was bedeutet es, wenn `ping` keine Antwort erhält, `traceroute` aber zeigt, dass die ersten hops erreichbar sind?
- Wofür steht die Abkürzung TTL (Time To Live), und wie nutzt `traceroute` sie, um die einzelnen hops sichtbar zu machen?

---

## Teil 4: Aktive Verbindungen und offene Ports untersuchen

1. Zeige alle aktiven network connections und listening ports deines Rechners an:
   ```
   ss -tulpn
   ```
   (Auf älteren Systemen alternativ: `netstat -tulpn`)
2. Identifiziere in der Ausgabe die Spalte `Local Address:Port` und notiere zwei geöffnete ports.
3. Ordne einem bekannten port (z. B. 22, 80 oder 443) den zugehörigen service zu (SSH, HTTP, HTTPS).
4. Prüfe, welcher process einen bestimmten port geöffnet hält, indem du die Spalte `Process` in der Ausgabe von Schritt 1 betrachtest (erfordert meist `sudo`).

**Verständnisfragen:**
- Was ist der Unterschied zwischen TCP und UDP im Hinblick auf listening ports?
- Warum kann es aus Sicherheitssicht sinnvoll sein zu wissen, welche ports auf deinem Rechner geöffnet sind?

---

<details>
<summary>Lösungen anzeigen</summary>

**Teil 1**
- `lo` ist die loopback-Schnittstelle mit der IP address `127.0.0.1`; sie dient der internen Kommunikation eines Rechners mit sich selbst und existiert unabhängig von jeder physischen Hardware. `eth0` (oder ähnlich benannte Interfaces) repräsentiert eine echte network interface (Kabel oder WLAN), über die der Rechner mit anderen Hosts kommuniziert.
- Das default gateway ist der Router, an den Pakete geschickt werden, wenn das Ziel nicht im lokalen Subnetz liegt. Ohne gateway kann der Rechner nur mit Hosts im selben lokalen Netzwerk kommunizieren.

**Teil 2**
- Der DNS server übersetzt den für Menschen lesbaren Domainnamen (`example.org`) in die numerische IP address, die für die eigentliche network connection benötigt wird.
- Ein typisches Linux-System prüft zuerst `/etc/hosts` (bzw. die Reihenfolge, die in `/etc/nsswitch.conf` definiert ist) und fragt erst danach, falls dort kein Eintrag gefunden wird, den konfigurierten DNS server ab.

**Teil 3**
- Das deutet meist auf eine Firewall oder Filterregel hin, die ICMP-Pakete (die `ping` benutzt) blockiert, während der eigentliche TCP/UDP-Traffic über dieselbe Route weiterhin funktionieren kann. Die Erreichbarkeit früher hops zeigt, dass die Route bis zu einem bestimmten Punkt funktioniert.
- TTL ist ein Feld im IP-Header, das bei jedem hop um 1 verringert wird. Erreicht es 0, verwirft der Router das Paket und sendet eine Fehlermeldung zurück. `traceroute` nutzt das gezielt: Es sendet Pakete mit steigender TTL (1, 2, 3, …), sodass jeder hop nacheinander antwortet und sichtbar wird.

**Teil 4**
- TCP ist verbindungsorientiert (mit Handshake und garantierter Zustellung), UDP ist verbindungslos und ohne Zustellungsgarantie. In der `ss`/`netstat`-Ausgabe erscheinen sie als getrennte Zeilen mit `tcp` bzw. `udp` als Protokoll.
- Offene ports zeigen an, welche services von außen erreichbar sind. Nicht benötigte offene ports vergrößern die Angriffsfläche des Systems, daher ist es wichtig zu wissen, welche ports aktiv sind und welcher process/service dafür verantwortlich ist.

</details>