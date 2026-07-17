# Geführte Übungen – Thema 1.2: Major Open Source Applications

**Zertifizierung:** LPI Linux Essentials (010-160, Version 1.6) · **Gewichtung:** 2

> **Voraussetzungen:** Ein Linux-System mit Terminal-Zugriff. Die Übungen funktionieren auf Debian/Ubuntu-basierten Systemen (mit `apt`/`dpkg`) und auf Fedora/RHEL-basierten Systemen (mit `dnf`/`rpm`). Wo sich die Befehle unterscheiden, werden beide Varianten gezeigt. Für die Installationsschritte brauchst du `sudo`-Rechte – wenn du sie nicht hast, führe nur die Such- und Abfrageschritte aus.

---

## Übung 1: Packages und Package Manager kennenlernen

Software wird unter Linux als **Package** ausgeliefert und mit einem **Package Manager** aus **Repositories** installiert. In dieser Übung findest du heraus, welches Package-Format dein System verwendet.

1. Stelle fest, welche Distribution du verwendest:

   ```bash
   cat /etc/os-release
   ```

2. Prüfe, welcher Low-Level-Package-Manager vorhanden ist:

   ```bash
   which dpkg rpm
   ```

   Nur einer der beiden sollte einen Pfad zurückgeben.

3. Liste alle installierten Packages auf und zähle sie:

   ```bash
   # Debian/Ubuntu:
   dpkg -l | wc -l

   # Fedora/RHEL:
   rpm -qa | wc -l
   ```

4. Frage ab, zu welchem Package ein bekannter Befehl gehört:

   ```bash
   # Debian/Ubuntu:
   dpkg -S /bin/ls

   # Fedora/RHEL:
   rpm -qf /bin/ls
   ```

**Fragen:**

- **1a.** Welches Package-Format verwenden Debian und Ubuntu, welches verwenden Fedora und Red Hat Enterprise Linux?
- **1b.** Was ist der Unterschied zwischen einem Low-Level-Tool wie `dpkg` und einem High-Level-Tool wie `apt`?
- **1c.** Was ist ein Repository?

---

## Übung 2: Desktop-Anwendungen – die Office-Suite LibreOffice

**LibreOffice** ist die wichtigste Open-Source-Office-Suite. Sie entstand als Fork von OpenOffice.org und verwendet das **Open Document Format (ODF)**.

1. Prüfe, ob LibreOffice installiert ist:

   ```bash
   which libreoffice && libreoffice --version
   ```

2. Suche die LibreOffice-Komponenten im Repository:

   ```bash
   # Debian/Ubuntu:
   apt search libreoffice-writer

   # Fedora/RHEL:
   dnf search libreoffice-writer
   ```

3. Erzeuge (falls LibreOffice installiert ist) aus einer Textdatei ein ODF-Dokument über die Kommandozeile:

   ```bash
   echo "Testdokument für Linux Essentials" > test.txt
   libreoffice --headless --convert-to odt test.txt
   ls -l test.odt
   ```

4. Sieh dir an, welchen Dateityp die erzeugte Datei hat:

   ```bash
   file test.odt
   ```

**Fragen:**

- **2a.** Ordne die LibreOffice-Komponenten ihrer Funktion zu: Writer, Calc, Impress, Base, Draw, Math.
- **2b.** Welche Dateiendungen verwendet ODF für Textdokumente, Tabellenkalkulationen und Präsentationen?
- **2c.** Warum zeigt `file test.odt` ein ZIP-basiertes Format an?

---

## Übung 3: Desktop-Anwendungen – Web, E-Mail und Grafik

Zu den prüfungsrelevanten Desktop-Anwendungen gehören der Browser **Firefox**, der E-Mail-Client **Thunderbird** und das Bildbearbeitungsprogramm **GIMP** (GNU Image Manipulation Program).

1. Prüfe die installierten Versionen (nicht alle müssen vorhanden sein):

   ```bash
   firefox --version
   thunderbird --version
   gimp --version
   ```

2. Suche in den Repositories nach weiteren Multimedia-Anwendungen:

   ```bash
   # Debian/Ubuntu:
   apt search --names-only "^vlc$|^blender$|^inkscape$"

   # Fedora/RHEL:
   dnf search vlc blender inkscape
   ```

3. Lies die Kurzbeschreibung eines Packages, ohne es zu installieren:

   ```bash
   # Debian/Ubuntu:
   apt show gimp

   # Fedora/RHEL:
   dnf info gimp
   ```

**Fragen:**

- **3a.** Welche Open-Source-Anwendung ist die Alternative zu Adobe Photoshop, welche zu Adobe Illustrator?
- **3b.** Von welcher Organisation stammen Firefox und Thunderbird?
- **3c.** Nenne je eine Open-Source-Anwendung für Video-Wiedergabe und für 3D-Modellierung.

---

## Übung 4: Server-Anwendungen – Web-Server und Datenbanken

Linux dominiert im Server-Bereich. Die wichtigsten Server-Anwendungen für die Prüfung: die Web-Server **Apache HTTP Server** und **NGINX**, die Datenbanken **MariaDB**/**MySQL** und **PostgreSQL**, sowie die Fileserver **Samba** und **NFS**.

1. Suche die Web-Server in den Repositories:

   ```bash
   # Debian/Ubuntu:
   apt show apache2 | head -n 10
   apt show nginx | head -n 10

   # Fedora/RHEL:
   dnf info httpd | head -n 15
   dnf info nginx | head -n 15
   ```

   Beachte: Das Apache-Package heißt je nach Distribution `apache2` oder `httpd`.

2. Installiere NGINX und starte ihn (nur wenn du eine Übungsumgebung mit `sudo` hast):

   ```bash
   # Debian/Ubuntu:
   sudo apt install nginx

   # Fedora/RHEL:
   sudo dnf install nginx
   sudo systemctl start nginx
   ```

3. Prüfe, ob der Web-Server antwortet:

   ```bash
   curl -I http://localhost
   ```

   Die Antwort sollte mit `HTTP/1.1 200 OK` beginnen und im Header `Server:` den Namen des Web-Servers zeigen.

4. Suche die Datenbank- und Fileserver-Packages:

   ```bash
   # Debian/Ubuntu:
   apt search --names-only "^mariadb-server$|^postgresql$|^samba$"

   # Fedora/RHEL:
   dnf search mariadb-server postgresql-server samba
   ```

**Fragen:**

- **4a.** Warum existieren MySQL und MariaDB parallel, und wie hängen sie zusammen?
- **4b.** Wofür wird Samba eingesetzt, und welches Protokoll implementiert es?
- **4c.** Was bedeutet der Begriff **LAMP stack**?

---

## Übung 5: Programmiersprachen und Shell-Scripts

Linux-Distributionen liefern mehrere Programmiersprachen mit. Prüfungsrelevant sind vor allem die **Shell** (Bash), **Python**, **Perl** und **C** – außerdem solltest du **PHP**, **Java**, **JavaScript** und **Ruby** einordnen können.

1. Prüfe, welche Interpreter installiert sind:

   ```bash
   bash --version | head -n 1
   python3 --version
   perl --version | head -n 2
   gcc --version | head -n 1
   ```

2. Führe eine Zeile Python direkt aus:

   ```bash
   python3 -c 'print("Linux Essentials 1.2")'
   ```

3. Erstelle ein kleines Shell-Script:

   ```bash
   cat > hallo.sh << 'EOF'
   #!/bin/bash
   echo "Dieses System läuft: $(uname -sr)"
   EOF
   chmod +x hallo.sh
   ./hallo.sh
   ```

4. Sieh nach, welcher Interpreter ein vorhandenes System-Script verwendet:

   ```bash
   head -n 1 /usr/bin/* 2>/dev/null | grep -B 1 "#!" | head -n 20
   ```

**Fragen:**

- **5a.** Welche Funktion hat die erste Zeile `#!/bin/bash` in einem Script, und wie heißt sie?
- **5b.** Worin unterscheidet sich eine kompilierte Sprache wie C von einer interpretierten Sprache wie Python?
- **5c.** Wozu diente `chmod +x hallo.sh` in Schritt 3?

---

## Übung 6: Packages installieren, aktualisieren und entfernen

Zum Abschluss der komplette Lebenszyklus eines Packages mit dem High-Level-Package-Manager. Verwende ein kleines, harmloses Package wie `cowsay`.

1. Aktualisiere die Package-Informationen aus den Repositories:

   ```bash
   # Debian/Ubuntu:
   sudo apt update

   # Fedora/RHEL:
   sudo dnf check-update
   ```

2. Installiere das Package und probiere es aus:

   ```bash
   # Debian/Ubuntu:
   sudo apt install cowsay

   # Fedora/RHEL:
   sudo dnf install cowsay

   cowsay "Open Source rocks"
   ```

3. Prüfe, welche Dateien das Package installiert hat:

   ```bash
   # Debian/Ubuntu:
   dpkg -L cowsay | head

   # Fedora/RHEL:
   rpm -ql cowsay | head
   ```

4. Entferne das Package wieder:

   ```bash
   # Debian/Ubuntu:
   sudo apt remove cowsay

   # Fedora/RHEL:
   sudo dnf remove cowsay
   ```

**Fragen:**

- **6a.** Was ist der Unterschied zwischen `apt update` und `apt upgrade`?
- **6b.** Was ist eine **dependency**, und warum ist ihre automatische Auflösung der große Vorteil von High-Level-Tools wie `apt` und `dnf`?
- **6c.** Mit welchem Befehl listest du auf einem RPM-System alle Dateien eines installierten Packages auf?

---

<details>
<summary><strong>Antworten anzeigen</strong></summary>

### Übung 1

- **1a.** Debian und Ubuntu verwenden das **deb**-Format (`.deb`-Dateien, verwaltet mit `dpkg`/`apt`). Fedora und Red Hat Enterprise Linux verwenden das **RPM**-Format (`.rpm`-Dateien, verwaltet mit `rpm`/`dnf`).
- **1b.** Low-Level-Tools (`dpkg`, `rpm`) arbeiten direkt mit einzelnen Package-Dateien und lösen keine Abhängigkeiten auf. High-Level-Tools (`apt`, `dnf`) laden Packages automatisch aus Repositories herunter und installieren fehlende **dependencies** gleich mit.
- **1c.** Ein Repository ist eine (meist online gehostete) Sammlung von Packages einer Distribution, aus der der Package Manager Software herunterlädt und installiert. Die Packages darin sind aufeinander abgestimmt und in der Regel signiert.

### Übung 2

- **2a.** **Writer** = Textverarbeitung, **Calc** = Tabellenkalkulation, **Impress** = Präsentationen, **Base** = Datenbank-Frontend, **Draw** = Zeichnungen/Diagramme, **Math** = Formeleditor.
- **2b.** `.odt` (OpenDocument Text), `.ods` (OpenDocument Spreadsheet), `.odp` (OpenDocument Presentation).
- **2c.** ODF-Dateien sind technisch ZIP-Archive, die XML-Dateien und eingebettete Ressourcen (z. B. Bilder) enthalten. `file` erkennt daher die ZIP-Container-Struktur mit dem ODF-MIME-Type.

### Übung 3

- **3a.** **GIMP** ist die Alternative zu Photoshop (Pixel-/Rastergrafik), **Inkscape** die Alternative zu Illustrator (Vektorgrafik).
- **3b.** Von der **Mozilla Foundation** (bzw. der Mozilla Corporation).
- **3c.** Video-Wiedergabe: **VLC** (VideoLAN Client); 3D-Modellierung: **Blender**.

### Übung 4

- **4a.** **MariaDB** ist ein **Fork** von MySQL. Er entstand, nachdem MySQL durch die Sun-/Oracle-Übernahme unter Oracles Kontrolle kam; die ursprünglichen Entwickler führten das Projekt unter neuem Namen als Community-Projekt weiter. MariaDB ist weitgehend kompatibel zu MySQL, viele Distributionen liefern standardmäßig MariaDB aus.
- **4b.** Samba stellt Datei- und Druckdienste für Windows-Clients bereit und ermöglicht die Integration von Linux-Servern in Windows-Netzwerke. Es implementiert das **SMB**-Protokoll (Server Message Block, auch CIFS genannt).
- **4c.** LAMP steht für **L**inux + **A**pache + **M**ySQL/MariaDB + **P**HP (alternativ Perl oder Python) – die klassische Open-Source-Kombination zum Betrieb dynamischer Websites.

### Übung 5

- **5a.** Die Zeile heißt **shebang** (auch hashbang). Sie teilt dem Kernel mit, welcher Interpreter das Script ausführen soll – hier `/bin/bash`.
- **5b.** C-Code wird von einem **Compiler** (z. B. `gcc`) einmalig in Maschinencode übersetzt; das Ergebnis läuft direkt auf der CPU. Python-Code wird zur Laufzeit von einem **Interpreter** Zeile für Zeile ausgeführt – kein separater Kompilierschritt, dafür meist langsamer in der Ausführung.
- **5c.** `chmod +x` setzt das **execute permission bit**. Ohne dieses Recht kann die Datei nicht als Programm gestartet werden (`./hallo.sh` würde mit „Permission denied" fehlschlagen).

### Übung 6

- **6a.** `apt update` aktualisiert nur die lokalen **Package-Indizes** (die Liste der verfügbaren Packages und Versionen aus den Repositories). `apt upgrade` installiert dann tatsächlich die neueren Versionen der bereits installierten Packages.
- **6b.** Eine dependency ist ein Package, das ein anderes Package zum Funktionieren benötigt (z. B. eine Library). High-Level-Tools ermitteln die komplette Abhängigkeitskette automatisch und installieren alles Nötige in einem Schritt – mit `dpkg`/`rpm` allein müsste man jede dependency von Hand besorgen.
- **6c.** `rpm -ql <packagename>` (q = query, l = list files).

</details>

---

**Quellen:**

- LPI Learning Materials, Lesson 1.2 „Major Open Source Applications": https://learning.lpi.org/en/learning-materials/010-160/1/1.2/