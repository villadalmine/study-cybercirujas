# 1.2 Major Open Source Applications

**Gewichtung im Examen: 2**

## Überblick

Linux ist weit mehr als nur ein Kernel: Erst die riesige Auswahl an Open-Source-Anwendungen macht das System für Desktop, Server und Entwicklung produktiv nutzbar. Für das Examen musst du die wichtigsten Anwendungen den Kategorien **Desktop**, **Server** und **Entwicklung** zuordnen können und die grundlegenden **Package-Management-Werkzeuge** der großen Distributionsfamilien kennen.

---

## Desktop-Anwendungen

### Office-Pakete

Die wichtigste freie Office-Suite ist **LibreOffice**, ein Fork von OpenOffice.org. Sie umfasst mehrere Komponenten, deren Namen du kennen solltest:

| Komponente | Zweck | Proprietäres Gegenstück |
|---|---|---|
| **Writer** | Textverarbeitung | Microsoft Word |
| **Calc** | Tabellenkalkulation | Microsoft Excel |
| **Impress** | Präsentationen | Microsoft PowerPoint |
| **Base** | Datenbank-Frontend | Microsoft Access |
| **Draw** | Vektorgrafik/Diagramme | Microsoft Visio |
| **Math** | Formeleditor | – |

LibreOffice verwendet standardmäßig das offene **OpenDocument Format (ODF)**: `.odt` (Text), `.ods` (Tabellen), `.odp` (Präsentationen). Es kann aber auch Microsoft-Formate wie `.docx` und `.xlsx` lesen und schreiben.

### Web-Browser und E-Mail

- **Mozilla Firefox** — der bekannteste Open-Source-Browser, entwickelt von der Mozilla Foundation.
- **Chromium** — die Open-Source-Basis von Google Chrome.
- **Mozilla Thunderbird** — E-Mail-Client mit Unterstützung für Kalender, Kontakte, RSS-Feeds und Newsgroups.

### Multimedia und Grafik

- **GIMP** (GNU Image Manipulation Program) — Bildbearbeitung, vergleichbar mit Adobe Photoshop.
- **Inkscape** — Vektorgrafik, vergleichbar mit Adobe Illustrator.
- **Blender** — 3D-Modellierung, Animation und Rendering; wird auch in professionellen Filmproduktionen eingesetzt.
- **Audacity** — Audio-Aufnahme und -Bearbeitung.
- **VLC Media Player** — spielt praktisch jedes Audio- und Videoformat ab.
- **ImageMagick** — Bildbearbeitung auf der Command Line, z. B. für Batch-Konvertierungen:

```bash
$ convert foto.png -resize 800x600 foto_klein.jpg
$ identify foto.png
foto.png PNG 1920x1080 1920x1080+0+0 8-bit sRGB 2.1MiB 0.000u 0:00.000
```

---

## Server-Anwendungen

Linux dominiert den Server-Markt. Diese Programme (und ihre Einsatzzwecke) sind prüfungsrelevant:

### Web-Server

- **Apache HTTP Server** (`httpd`) — der klassische, modulare Web-Server.
- **NGINX** — moderner Web-Server und Reverse Proxy, besonders effizient bei vielen gleichzeitigen Verbindungen.

### Datenbank-Server

- **MariaDB** — Community-Fork von **MySQL**; relationales Datenbanksystem (RDBMS), das SQL verwendet.
- **PostgreSQL** — funktionsreiches, standardkonformes RDBMS.
- **SQLite** — leichtgewichtige, dateibasierte Datenbank ohne eigenen Server-Prozess.

### Datei- und Druckdienste

- **Samba** — stellt Datei- und Druckdienste über das **SMB/CIFS**-Protokoll bereit und ermöglicht so die Integration von Linux in Windows-Netzwerke.
- **NFS** (Network File System) — klassische Dateifreigabe zwischen Unix/Linux-Systemen.
- **CUPS** (Common Unix Printing System) — Druckserver-System unter Linux.

### E-Mail-Server (MTAs)

Ein **Mail Transfer Agent (MTA)** transportiert E-Mails zwischen Servern per **SMTP**:

- **Postfix** — moderner, sicherheitsorientierter MTA, heute der De-facto-Standard.
- **Sendmail** — der historische Unix-MTA.
- **Exim** — flexibler MTA, Standard bei Debian.
- **Dovecot** — kein MTA, sondern ein **IMAP/POP3**-Server für den Abruf von Mails.

### Cloud und Virtualisierung

- **Nextcloud** / **ownCloud** — selbst gehostete File-Sync-and-Share-Plattformen (private Cloud); Nextcloud ist ein Fork von ownCloud.
- **OpenStack** — Plattform zum Aufbau von Infrastructure-as-a-Service (IaaS)-Clouds.
- **KVM** (Kernel-based Virtual Machine) — die in den Linux-Kernel integrierte Virtualisierungslösung.

---

## Entwicklungssprachen

Linux selbst und viele seiner Werkzeuge sind in diesen Sprachen geschrieben — du solltest sie grob einordnen können:

- **C** — der Linux-Kernel und die meisten Systemwerkzeuge sind in C geschrieben; kompilierte Sprache.
- **C++** — objektorientierte Erweiterung von C; z. B. für Desktop-Umgebungen wie KDE.
- **Shell (Bash)** — Skriptsprache für Systemadministration und Automatisierung.
- **Python** — vielseitige, leicht lesbare Interpretersprache; sehr verbreitet in Administration, Data Science und Web-Entwicklung.
- **Perl** — klassische Sprache für Textverarbeitung und Systemskripte.
- **PHP** — serverseitige Web-Programmierung (z. B. WordPress, Nextcloud).
- **JavaScript** — Sprache des Web-Browsers; mit **Node.js** auch serverseitig.
- **Java** — plattformunabhängige, kompilierte Sprache (läuft auf der Java Virtual Machine).

Versionen prüfen:

```bash
$ python3 --version
Python 3.12.3
$ bash --version | head -n 1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
$ perl -e 'print "Hallo von Perl\n";'
Hallo von Perl
```

---

## Package Management

Software wird unter Linux als **Package** installiert — ein Archiv mit dem Programm, seinen Dateien und Metadaten (u. a. **Dependencies**). Packages kommen aus **Repositories**: von der Distribution gepflegte Server mit geprüfter Software. Es gibt zwei große Familien:

### Debian-Familie (Debian, Ubuntu, Linux Mint)

Format: **`.deb`** — Low-Level-Tool: **`dpkg`** — High-Level-Tool mit Repository- und Dependency-Verwaltung: **APT** (`apt`, `apt-get`).

```bash
$ sudo apt update                 # Paketlisten der Repositories aktualisieren
$ sudo apt install gimp           # Package inkl. Dependencies installieren
$ sudo apt remove gimp            # Package entfernen
$ dpkg -l | grep libreoffice      # installierte Packages auflisten
ii  libreoffice-writer  4:24.2.7-0ubuntu0.24.04.1  amd64  office suite - word processor
```

### Red-Hat-Familie (RHEL, Fedora, CentOS Stream, openSUSE*)

Format: **`.rpm`** — Low-Level-Tool: **`rpm`** — High-Level-Tools: **`dnf`** (Nachfolger von `yum`) bzw. **`zypper`** bei openSUSE/SUSE.

```bash
$ sudo dnf install httpd          # Apache installieren (Fedora/RHEL)
$ sudo dnf upgrade                # alle Packages aktualisieren
$ rpm -q firefox                  # Version eines installierten Packages abfragen
firefox-128.0-1.fc40.x86_64
$ sudo zypper install nginx       # openSUSE
```

\* openSUSE nutzt das RPM-Format, aber `zypper` statt `dnf`.

### Distributionsübergreifende Formate

Neuere Formate bündeln Anwendungen mit ihren Dependencies und funktionieren auf vielen Distributionen: **Flatpak**, **Snap** und **AppImage**.

**Merksatz für das Examen:** Debian-Welt = `.deb` + `dpkg` + `apt`; Red-Hat-Welt = `.rpm` + `rpm` + `dnf`/`yum` (bzw. `zypper` bei SUSE).

---

## Zusammenfassung

- **Desktop:** LibreOffice (Writer, Calc, Impress), Firefox, Thunderbird, GIMP, Inkscape, Blender, Audacity, VLC.
- **Server:** Apache/NGINX (Web), MariaDB/MySQL/PostgreSQL (Datenbank), Samba/NFS (Dateien), Postfix/Sendmail/Exim (Mail, SMTP), Dovecot (IMAP/POP3), Nextcloud/ownCloud (private Cloud), OpenStack (IaaS).
- **Sprachen:** C (Kernel), Shell/Python/Perl (Skripte/Administration), PHP/JavaScript (Web), Java, C++.
- **Packages:** `.deb`/`dpkg`/`apt` vs. `.rpm`/`rpm`/`dnf`/`zypper`; Software kommt aus Repositories; Flatpak/Snap/AppImage sind distributionsübergreifend.

---

## Referenzen

- LPI Learning Materials, Topic 1.2: https://learning.lpi.org/en/learning-materials/010-160/1/1.2/
- LibreOffice-Dokumentation: https://documentation.libreoffice.org/
- Mozilla Firefox: https://www.mozilla.org/firefox/ — Thunderbird: https://www.thunderbird.net/
- GIMP: https://www.gimp.org/docs/ — Blender: https://docs.blender.org/ — VLC: https://www.videolan.org/doc/
- Apache HTTP Server: https://httpd.apache.org/docs/ — NGINX: https://nginx.org/en/docs/
- MariaDB: https://mariadb.org/documentation/ — PostgreSQL: https://www.postgresql.org/docs/
- Samba: https://www.samba.org/samba/docs/ — Postfix: https://www.postfix.org/documentation.html
- Nextcloud: https://docs.nextcloud.com/ — OpenStack: https://docs.openstack.org/
- Debian-Paketverwaltung (APT): https://www.debian.org/doc/manuals/debian-faq/pkgtools.en.html
- Fedora DNF: https://docs.fedoraproject.org/en-US/quick-docs/dnf/
- Flatpak: https://docs.flatpak.org/ — Snap: https://snapcraft.io/docs — AppImage: https://docs.appimage.org/