# Übung: Thema 1.4 – ICT Skills and Working in Linux

**Quelle (Referenz):** https://learning.lpi.org/en/learning-materials/010-160/1/1.4/

---

## Übung 1: Das Terminal öffnen und erste Befehle ausführen

1. Öffne auf deinem Desktop (egal ob GNOME, KDE oder Xfce) die Anwendungsübersicht und suche nach "Terminal" oder "Konsole".
2. Starte das Terminal-Programm. Es öffnet sich eine Eingabeaufforderung (Prompt), meist mit deinem Benutzernamen, dem Hostnamen und dem aktuellen Verzeichnis.
3. Führe den Befehl `whoami` aus und notiere die Ausgabe.
4. Führe den Befehl `pwd` (print working directory) aus und notiere, in welchem Verzeichnis du dich befindest.
5. Führe `ls -la` aus, um alle Dateien (auch versteckte, beginnend mit `.`) im aktuellen Verzeichnis mit Details anzuzeigen.

**F1:** Was ist der Unterschied zwischen der grafischen Oberfläche (GUI) und der Kommandozeile (CLI), wenn es um das Ausführen von Aufgaben geht?

**F2:** Warum zeigt `ls` versteckte Dateien standardmäßig nicht an, und mit welcher Option werden sie sichtbar?

---

## Übung 2: Dateiverwaltung über den grafischen Dateimanager

1. Öffne den Dateimanager deiner Distribution (z. B. Nautilus, Dolphin oder Thunar) über die Anwendungsübersicht.
2. Navigiere zu deinem Home-Verzeichnis (meist als Haus-Symbol oder `~` dargestellt).
3. Erstelle über das Kontextmenü (Rechtsklick) einen neuen Ordner mit dem Namen `uebung14`.
4. Erstelle im Ordner `uebung14` eine leere Textdatei mit dem Namen `notiz.txt`.
5. Kopiere `notiz.txt` in denselben Ordner, sodass eine Kopie (z. B. `notiz (Kopie).txt`) entsteht, und lösche anschließend diese Kopie über den Papierkorb.
6. Wechsle zurück ins Terminal aus Übung 1 und bestätige mit `ls ~/uebung14`, dass die Datei `notiz.txt` existiert.

**F3:** Welches Verzeichnis gilt als "root directory" des gesamten Dateisystems, und wie unterscheidet es sich vom Home-Verzeichnis eines Benutzers?

**F4:** Warum landen gelöschte Dateien im Dateimanager meist zuerst im Papierkorb, statt sofort permanent entfernt zu werden?

---

## Übung 3: Lokal und remote (SSH) einloggen

1. Logge dich, falls noch nicht geschehen, lokal an deinem Linux-System mit deinem Benutzernamen und Passwort an (Login-Bildschirm oder virtuelle Konsole, z. B. mit `Strg+Alt+F3`).
2. Kehre mit `Strg+Alt+F1` (oder der entsprechenden Tastenkombination deiner Distribution) zur grafischen Oberfläche zurück.
3. Prüfe im Terminal mit `ip a` oder `hostname -I`, ob dein System eine IP-Adresse im lokalen Netzwerk hat.
4. Falls ein zweites Linux-System (oder eine virtuelle Maschine) im selben Netzwerk erreichbar ist und einen SSH-Server (`sshd`) laufen hat, verbinde dich remote mit: `ssh benutzername@ip-adresse`.
5. Bestätige beim ersten Verbindungsaufbau den Fingerprint des Zielrechners und melde dich mit dem Passwort an.
6. Führe auf dem remote System `hostname` aus, um zu bestätigen, dass du tatsächlich auf dem anderen Rechner arbeitest, und beende die Sitzung mit `exit`.

**F5:** Was ist der grundlegende Unterschied zwischen einem lokalen Login und einem Remote-Login per SSH?

**F6:** Wofür dient der beim ersten SSH-Verbindungsaufbau angezeigte Host-Key-Fingerprint?

---

## Übung 4: Hilfe auf der Kommandozeile finden

1. Führe `man ls` aus, um die vollständige Manual-Page des Befehls `ls` zu öffnen.
2. Navigiere mit den Pfeiltasten oder `Leertaste`/`b` durch die Seite und verlasse sie mit `q`.
3. Führe `ls --help` aus und vergleiche die Kürze dieser Ausgabe mit der `man`-Page.
4. Suche innerhalb einer `man`-Page nach einem Begriff, indem du in `man ls` `/recursive` eingibst und mit `n` zur nächsten Fundstelle springst.
5. Führe `whatis ls` aus, um eine Ein-Zeilen-Beschreibung des Befehls zu erhalten.

**F7:** Wann ist `--help` ausreichend, und wann solltest du stattdessen die `man`-Page konsultieren?

**F8:** Welche weiteren Anlaufstellen (außer `man`-Pages) nennt LPI, um sich über Linux-Themen zu informieren?

---

## Übung 5: Softwarepakete verwalten

1. Finde heraus, welches Package-Management-System deine Distribution verwendet (z. B. `apt` bei Debian/Ubuntu, `dnf` bei Fedora/RHEL, `zypper` bei openSUSE).
2. Aktualisiere die Paketlisten: bei Debian/Ubuntu mit `sudo apt update`, bei Fedora mit `sudo dnf check-update`.
3. Suche nach einem harmlosen Paket, z. B. `sudo apt search cowsay` bzw. `dnf search cowsay`.
4. Installiere es: `sudo apt install cowsay` bzw. `sudo dnf install cowsay`.
5. Führe das installierte Programm testweise aus (`cowsay "Linux Essentials"`).
6. Entferne das Paket anschließend wieder: `sudo apt remove cowsay` bzw. `sudo dnf remove cowsay`.

**F9:** Welchen Vorteil bietet die Installation über die offiziellen Paketquellen (Repositories) der Distribution gegenüber dem manuellen Download eines Installationspakets aus dem Internet?

**F10:** Warum benötigen Installation und Entfernung von Paketen in der Regel Root-Rechte (`sudo`)?

---

## Übung 6: Sicherheit prüfen – GPG-Signaturen

1. Suche im Internet eine offizielle Download-Seite eines Open-Source-Projekts, die neben der Datei auch eine `.asc`- oder `.sig`-Datei sowie einen SHA256-Prüfsummenwert anbietet (z. B. eine bekannte Linux-Distribution-ISO).
2. Lade beide Dateien herunter: das eigentliche Paket und die zugehörige Signatur- bzw. Prüfsummendatei.
3. Berechne lokal die Prüfsumme der heruntergeladenen Datei mit `sha256sum dateiname` und vergleiche sie manuell mit dem auf der Webseite veröffentlichten Wert.
4. Falls ein GPG-Public-Key des Projekts verfügbar ist, importiere ihn mit `gpg --import key.asc` und verifiziere die Signatur mit `gpg --verify dateiname.sig dateiname`.

**F11:** Welches Sicherheitsrisiko soll durch die Prüfung von Prüfsummen (Checksums) und GPG-Signaturen vor der Installation heruntergeladener Software vermieden werden?

**F12:** Was bedeutet es, wenn `gpg --verify` eine "Good signature" meldet, aber gleichzeitig davor warnt, dass der Schlüssel nicht vertrauenswürdig zertifiziert ist?

---

## Übung 7: Grundbegriffe der Virtualisierung

1. Recherchiere die Begriffe "Host", "Guest", "Hypervisor Typ 1" und "Hypervisor Typ 2" und notiere für jeden eine eigene, kurze Definition.
2. Falls auf deinem System ein Virtualisierungswerkzeug wie VirtualBox, GNOME Boxes oder KVM/QEMU installiert ist, öffne es und sieh dir die Liste eventuell vorhandener virtueller Maschinen an (auch wenn keine existiert, reicht das Öffnen der Übersicht).
3. Vergleiche im Terminal mit `lscpu`, ob dein Prozessor Virtualisierungserweiterungen (`VT-x`/`AMD-V`, sichtbar als Flag `vmx` oder `svm`) unterstützt, z. B. mit `grep -E "vmx|svm" /proc/cpuinfo`.

**F13:** Was unterscheidet eine klassische virtuelle Maschine (VM) begrifflich von einem Container?

**F14:** Ist ein typischer Desktop-Hypervisor wie VirtualBox ein Typ-1- oder ein Typ-2-Hypervisor, und worin liegt der Unterschied zu einem Typ-1-Hypervisor wie KVM auf einem Server?

---

<details>
<summary>Lösungen anzeigen</summary>

**F1:** Die GUI bietet eine visuelle, klickbasierte Bedienung, die intuitiv, aber oft langsamer bei wiederholbaren oder komplexen Aufgaben ist. Die CLI erlaubt präzise, skriptfähige und automatisierbare Befehle, erfordert aber das Erlernen der Syntax. Beide greifen letztlich auf dieselbe Systemfunktionalität zu.

**F2:** `ls` blendet Dateien, deren Name mit einem Punkt (`.`) beginnt, standardmäßig aus, da diese Konvention für Konfigurations- und "versteckte" Dateien genutzt wird, die im Alltag meist nicht benötigt werden. Mit der Option `-a` (bzw. `-la` für zusätzliche Details) werden sie eingeblendet.

**F3:** Das root directory (`/`) ist der oberste Punkt der gesamten Verzeichnishierarchie, unter dem alle anderen Verzeichnisse und Dateisysteme eingehängt sind. Das Home-Verzeichnis eines Benutzers (z. B. `/home/benutzername`) ist nur ein Teilbereich davon, in dem dieser Benutzer persönliche Dateien ablegt und volle Schreibrechte besitzt.

**F4:** Der Papierkorb dient als Sicherheitspuffer: Er ermöglicht es, versehentlich gelöschte Dateien wiederherzustellen, bevor sie endgültig und unwiederbringlich entfernt werden.

**F5:** Beim lokalen Login erfolgt die Authentifizierung direkt an der physischen Konsole des Rechners. Beim Remote-Login über SSH wird eine verschlüsselte Netzwerkverbindung zu einem anderen (entfernten) System aufgebaut, auf dem man sich anschließend genauso authentifiziert und arbeitet, als säße man direkt davor.

**F6:** Der Host-Key-Fingerprint erlaubt es dem Client, die Identität des Zielservers zu überprüfen, um sogenannte Man-in-the-Middle-Angriffe zu erkennen: Ändert sich der Fingerprint unerwartet, könnte man mit einem anderen (potenziell bösartigen) System statt dem erwarteten Server verbunden sein.

**F7:** `--help` liefert eine knappe Übersicht der wichtigsten Optionen und eignet sich für einen schnellen Blick auf bereits bekannte Befehle. Die `man`-Page bietet eine vollständige, oft mit Beispielen versehene Dokumentation und ist die richtige Wahl, wenn man einen Befehl gründlich verstehen oder eine seltene Option nachschlagen möchte.

**F8:** Neben `man`-Pages nennt LPI u. a. Online-Dokumentationen der Distributionen, Foren und Community-Mailinglisten, Wikis (z. B. ArchWiki), sowie `info`-Seiten und die Dokumentation einzelner Softwareprojekte selbst.

**F9:** Offizielle Repositories bieten Pakete, die von der Distribution auf Kompatibilität und Sicherheit geprüft, digital signiert und zentral mit Updates versorgt werden. Ein manueller Download umgeht diese Prüfungen und Update-Mechanismen und birgt ein höheres Risiko für manipulierte oder veraltete Software.

**F10:** Die Installation und Entfernung von Paketen verändert systemweite Dateien (z. B. in `/usr` oder `/etc`), auf die normale Benutzer keinen Schreibzugriff haben. Root-Rechte stellen sicher, dass solche weitreichenden Änderungen bewusst und kontrolliert erfolgen.

**F11:** Ohne Prüfsummen- oder Signaturverifikation könnte eine heruntergeladene Datei unbemerkt durch eine manipulierte, mit Schadsoftware versehene Version ersetzt worden sein (z. B. durch einen kompromittierten Mirror-Server oder einen Man-in-the-Middle-Angriff). Die Prüfung stellt sicher, dass die Datei tatsächlich unverändert vom Herausgeber stammt.

**F12:** "Good signature" bestätigt, dass die Datei tatsächlich mit dem privaten Schlüssel signiert wurde, der zum importierten öffentlichen Schlüssel passt, und seit der Signierung nicht verändert wurde. Die Warnung über fehlendes Vertrauen bedeutet lediglich, dass man die Identität des Schlüsselinhabers selbst nicht anderweitig (z. B. über das Web of Trust) bestätigt hat – die Datei könnte also technisch unverändert, aber der Schlüssel selbst nicht zweifelsfrei verifiziert sein.

**F13:** Eine VM virtualisiert komplette Hardware inklusive eines eigenen Betriebssystemkerns (Kernel) und wird vom Hypervisor verwaltet. Ein Container teilt sich den Kernel des Host-Betriebssystems und isoliert lediglich Prozesse, Dateisystem und Netzwerk auf Betriebssystemebene, wodurch er wesentlich leichtgewichtiger ist als eine VM.

**F14:** VirtualBox ist ein Typ-2-Hypervisor, der als gewöhnliche Anwendung auf einem bereits laufenden Host-Betriebssystem installiert wird. KVM ist ein Typ-1-Hypervisor (genauer: in den Linux-Kernel integriert und arbeitet bare-metal-nah), der direkt auf der Hardware läuft, ohne ein vollwertiges Host-Betriebssystem als Vermittler zu benötigen, was in der Regel bessere Performance für Server-Umgebungen bietet.

</details>