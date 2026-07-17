# 1.4 ICT Skills and Working in Linux

**Gewichtung im Exam: 2**

## Überblick

Dieses Thema deckt grundlegende ICT-Kompetenzen ab, die für die tägliche Arbeit an einem Linux-System notwendig sind: die Bedienung grafischer Oberflächen (GUI) im Vergleich zur Kommandozeile (CLI/shell), grundlegende Dateiverwaltung, der Umgang mit gängigen Anwendungen, das Einholen von Hilfe sowie ein Basisverständnis von Sicherheit und Cloud-Konzepten. Es ist eher praktisch orientiert als theorielastig – die Prüfung erwartet, dass man weiß, *wie* man an einem Linux-System arbeitet, nicht nur *was* Linux ist.

## GUI vs. Command Line

Linux-Distributionen bieten in der Regel sowohl eine **graphical user interface (GUI)** – z. B. GNOME, KDE Plasma, Xfce – als auch eine **command line interface (CLI)** über ein **terminal emulator**-Programm (z. B. GNOME Terminal, Konsole, xterm).

- Die GUI eignet sich für alltägliche Aufgaben: Dateien per Drag-and-drop verschieben, Anwendungen über ein Menü starten, Einstellungen über Dialogfenster ändern.
- Die **shell** (z. B. `bash`) erlaubt präzise, wiederholbare und automatisierbare Aktionen und ist oft schneller für Systemadministrationsaufgaben.
- Viele Distributionen bieten auch reine Terminal-Umgebungen ohne GUI an (Server, Container, eingebettete Systeme), daher ist CLI-Kompetenz unverzichtbar.

Ein Terminal öffnet man in den meisten Desktop-Umgebungen über das Anwendungsmenü oder ein Tastenkürzel (z. B. `Ctrl+Alt+T` in vielen GNOME/Ubuntu-Varianten).

## Grundlegende Kommandozeilen-Nutzung

Ein einfacher Workaround, um sich in der shell zurechtzufinden:

```bash
$ pwd
/home/anna

$ ls
Documents  Downloads  Pictures  notes.txt

$ cd Documents
$ ls -l
-rw-r--r-- 1 anna anna  1240 Jul 10 09:15 report.odt
drwxr-xr-x 2 anna anna  4096 Jul 10 09:16 slides
```

Wichtige Grundkonzepte:

- `pwd` (print working directory) zeigt das aktuelle Verzeichnis.
- `ls` listet Inhalte auf, `ls -l` zeigt zusätzlich **permissions**, Eigentümer und Größe.
- Mit den Pfeiltasten (↑/↓) kann man in der **command history** frühere Befehle wiederholen; `history` zeigt die komplette Liste.
- **Tab completion** vervollständigt Datei- und Befehlsnamen automatisch und reduziert Tippfehler.

## Dateiverwaltung: GUI und CLI im Vergleich

Dieselbe Aufgabe lässt sich meist auf zwei Wegen lösen:

| Aktion | GUI (file manager) | Command line |
|---|---|---|
| Datei kopieren | Kopieren + Einfügen | `cp quelle.txt ziel.txt` |
| Datei verschieben | Drag-and-drop | `mv datei.txt ~/Documents/` |
| Ordner anlegen | Rechtsklick → „Neuer Ordner" | `mkdir projekt` |
| Datei löschen | In den Papierkorb ziehen | `rm datei.txt` |
| Datei umbenennen | F2 / Rechtsklick → Umbenennen | `mv alt.txt neu.txt` |

```bash
$ mkdir projekt
$ cp notes.txt projekt/
$ mv projekt/notes.txt projekt/meeting-notes.txt
$ rm projekt/meeting-notes.txt
```

Ein wichtiger Unterschied: In der GUI landen gelöschte Dateien meist im Papierkorb (**trash**) und sind wiederherstellbar, während `rm` auf der Kommandozeile Dateien in der Regel **sofort und ohne Papierkorb** entfernt.

## Gängige Anwendungen (Productivity)

Für alltägliche ICT-Aufgaben stehen unter Linux typischerweise Open-Source-Alternativen zur Verfügung:

- **Office-Suite**: LibreOffice (Writer, Calc, Impress) als Alternative zu Microsoft Office.
- **Browser**: Firefox, Chromium.
- **E-Mail-Client**: Thunderbird.
- **Bildbearbeitung**: GIMP.

Diese Anwendungen lassen sich über den **package manager** der Distribution installieren, z. B.:

```bash
$ sudo apt install libreoffice thunderbird
```

## Suche im Internet effizient nutzen

ICT-Kompetenz umfasst auch, Suchmaschinen gezielt einzusetzen, z. B. durch Suchoperatoren:

```
"exact phrase"        # exakte Wortfolge
site:example.com      # Suche nur auf einer bestimmten Domain
filetype:pdf          # nur bestimmte Dateitypen
-wort                 # Wort ausschließen
```

Solche Operatoren sparen Zeit gegenüber unstrukturierten Suchanfragen und sind besonders bei der Fehlersuche (z. B. bei einer Fehlermeldung im Terminal) nützlich.

## Hilfe einholen

Linux bietet mehrere eingebaute Hilfe-Mechanismen, bevor man online suchen muss:

```bash
$ man ls          # vollständige manual page zu ls
$ ls --help       # Kurzübersicht der Optionen
$ whatis ls       # Ein-Zeilen-Beschreibung
```

Darüber hinaus gibt es projektspezifische Ressourcen:

- **Mailing lists** – Diskussion und Support direkt mit Entwicklern/Community.
- **Forums** – z. B. distributionsspezifische Foren (Ubuntu Forums, Arch Wiki-Forum).
- **Issue/bug trackers** – z. B. auf GitHub oder GitLab, um Fehler zu melden oder bekannte Probleme zu finden.
- **IRC/Chat-Kanäle** – Echtzeit-Support in vielen Open-Source-Communities.

## Sicherheitsbewusstsein (Security Basics)

Grundlegende ICT-Sicherheitspraktiken, die auch für den Umgang mit Linux relevant sind:

- **Starke Passwörter**: ausreichende Länge, Mischung aus Zeichentypen, keine Wiederverwendung über mehrere Dienste. Passwort ändern:

```bash
$ passwd
```

- **Verschlüsselung**: Verbindungen möglichst über verschlüsselte Protokolle abwickeln, z. B. **SSH** statt Telnet für Remote-Zugriff, **HTTPS** statt HTTP im Browser.

```bash
$ ssh anna@server.example.com
```

- **Malware/Phishing-Bewusstsein**: keine unbekannten Anhänge öffnen, Herkunft von Software prüfen (offizielle **package manager**-Repositories statt beliebiger Downloads).
- **File permissions** als Sicherheitsmechanismus: nur notwendige Zugriffsrechte vergeben (Prinzip der geringsten Rechte), sichtbar über `ls -l`.

## Virtualisierung und Cloud-Konzepte

Grundbegriffe, die im ICT-Alltag zunehmend relevant sind:

- **Virtualization**: Ein Hypervisor (z. B. KVM, VirtualBox) erlaubt, mehrere **virtual machines (VMs)** auf einer physischen Maschine laufen zu lassen – nützlich zum Testen von Software oder für isolierte Umgebungen.
- **Cloud computing**-Servicemodelle:
  - **IaaS** (Infrastructure as a Service) – z. B. virtuelle Server (AWS EC2).
  - **PaaS** (Platform as a Service) – eine Laufzeitumgebung ohne eigene Serververwaltung (z. B. Heroku).
  - **SaaS** (Software as a Service) – fertige Anwendungen über den Browser (z. B. Google Docs).

Diese Modelle unterscheiden sich im Grad der Kontrolle, die der Nutzer über die zugrunde liegende Infrastruktur hat, gegenüber dem, was der Anbieter verwaltet.

## Referenzen

- LPI Learning Materials – Linux Essentials, Topic 1.4: https://learning.lpi.org/en/learning-materials/010-160/1/1.4/
- LPI Linux Essentials Exam Objectives (010-160): https://www.lpi.org/our-exams/exam-1-linux-essentials
- man-pages Projekt: https://man7.org/linux/man-pages/
- LibreOffice Dokumentation: https://documentation.libreoffice.org/
- Arch Wiki (allgemeine Linux-Referenz): https://wiki.archlinux.org/