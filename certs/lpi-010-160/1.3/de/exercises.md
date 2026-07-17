# Übung: Open Source Software and Licensing

*LPI Linux Essentials (010-160, v1.6) – Thema 1.3, Gewichtung: 1*
*Quelle (Referenz, keine wörtliche Übernahme): https://learning.lpi.org/en/learning-materials/010-160/1/1.3/*

> Hinweis: Die Befehle sind für Debian/Ubuntu (`dpkg`, `apt`) angegeben. Auf RPM-basierten Distributionen (Fedora, RHEL) verwende stattdessen `rpm` bzw. `dnf`, wo angegeben.

---

## Übung 1: Lizenzinformationen von installierter Software ermitteln

1. Öffne ein Terminal.
2. Liste alle installierten Pakete auf: `dpkg -l | less` (Debian/Ubuntu) bzw. `rpm -qa | less` (Fedora/RHEL).
3. Wähle ein bekanntes Paket, z. B. `bash`, und zeige dessen Metadaten an: `apt show bash` (Debian/Ubuntu) bzw. `rpm -qi bash` (Fedora/RHEL).
4. Auf Debian/Ubuntu enthält `apt show` meist kein direktes "License"-Feld – öffne stattdessen die Copyright-Datei: `less /usr/share/doc/bash/copyright`. Auf RPM-Systemen erscheint das Feld "License" direkt in der Ausgabe von `rpm -qi`.
5. Notiere dir, welche Lizenz für `bash` angegeben ist.

**Fragen:**
- Welche Lizenz verwendet `bash` laut deiner Ausgabe?
- Handelt es sich dabei um eine Copyleft License oder eine Permissive License?

---

## Übung 2: Den Volltext einer Copyleft-Lizenz lesen (GPL)

1. Suche die lokale Volltextdatei der GNU General Public License: `find /usr/share -iname "*GPL*" 2>/dev/null`.
2. Öffne eine der gefundenen Dateien, z. B. `less /usr/share/common-licenses/GPL-3`.
3. Suche innerhalb von `less` nach dem Begriff "source code", indem du `/source code` eintippst und Enter drückst.
4. Lies den Absatz um den Fundort und verlasse den Pager anschließend mit `q`.

**Fragen:**
- Welche Pflicht entsteht laut GPL für jemanden, der ein GPL-lizenziertes Programm verändert und weiterverteilt?
- Wie lautet der englische Fachbegriff für dieses Lizenzprinzip?

---

## Übung 3: Permissive License vs. Copyleft vergleichen (BSD/MIT)

1. Suche nach einer BSD- oder MIT-lizenzierten Komponente auf deinem System:
   `grep -l -i "BSD\|MIT License" /usr/share/doc/*/copyright 2>/dev/null | head -5`
2. Öffne eine der gefundenen Dateien mit `less`.
3. Vergleiche den Wortlaut mit dem GPL-Text aus Übung 2: Enthält die BSD/MIT-Lizenz eine Pflicht, den Quellcode abgeleiteter Werke offenzulegen?

**Fragen:**
- Was ist der zentrale Unterschied zwischen einer Permissive License (BSD/MIT) und einer Copyleft License (GPL) im Hinblick auf abgeleitete Werke (derivative works)?
- Nenne ein Beispiel für Software, die üblicherweise unter einer permissiven Lizenz steht.

---

## Übung 4: FOSS-Anwendungen auf dem eigenen System identifizieren

1. Öffne deinen Webbrowser und rufe die "Über"-Seite auf (z. B. über das Hilfe-Menü → "Über ...").
2. Notiere Namen und Versionsnummer des Browsers.
3. Prüfe im Terminal, unter welcher Lizenz der Browser steht, z. B.: `less /usr/share/doc/firefox*/copyright 2>/dev/null`.
4. Wiederhole den Vorgang für eine Büroanwendung wie LibreOffice: `less /usr/share/doc/libreoffice-core/copyright 2>/dev/null`.

**Fragen:**
- Nenne zwei Kategorien von FOSS-Anwendungen, die typischerweise auf einem Linux-Desktop vorinstalliert sind.
- Warum ist es für Anwender relevant zu wissen, unter welcher Lizenz eine Anwendung steht?

---

## Übung 5: Software Repository und Ecosystem erkunden

1. Zeige die konfigurierten Paketquellen (Repositories) an: `cat /etc/apt/sources.list` sowie die Dateien in `/etc/apt/sources.list.d/` (Debian/Ubuntu) bzw. `dnf repolist` (Fedora/RHEL).
2. Aktualisiere den lokalen Paketindex: `sudo apt update` bzw. `sudo dnf check-update`.
3. Suche im Repository nach einem Programm deiner Wahl, z. B.: `apt search editor | head -10` bzw. `dnf search editor`.
4. Beobachte, wie viele unterschiedliche FOSS-Programme über die offiziellen Repositories deiner Distribution verfügbar sind.

**Fragen:**
- Welche Rolle spielt ein Software Repository innerhalb des Open-Source-Ecosystems?
- Was unterscheidet ein offizielles Distributions-Repository von einer Drittanbieterquelle (third-party repository)?

---

## Übung 6: Creative Commons von Software-Lizenzen abgrenzen

1. Öffne, falls Internetzugang vorhanden, die Seite https://creativecommons.org/licenses/ und sieh dir die Übersicht der CC-Varianten an (z. B. CC BY, CC BY-SA, CC0).
2. Suche in der lokalen Dokumentation deiner Distribution (z. B. README-Dateien unter `/usr/share/doc/`) nach einem Hinweis auf eine Creative-Commons-Lizenz: `grep -rl -i "creative commons" /usr/share/doc/*/README* 2>/dev/null`.
3. Vergleiche gedanklich: Für welche Art von Werk (Code vs. Dokumentation/Bild/Text) wird die jeweilige Lizenzfamilie typischerweise eingesetzt?

**Fragen:**
- Warum ist Creative Commons in der Regel nicht für Software-Quellcode geeignet?
- Was ist der Hauptunterschied zwischen CC0 und CC BY-SA?

---

<details>
<summary>Antworten anzeigen</summary>

**Übung 1**
- Die genaue Lizenz hängt von der installierten `bash`-Version und Distribution ab; in der Copyright-Datei bzw. im License-Feld steht üblicherweise **GPL-3+** (GNU General Public License, Version 3 oder später).
- Das ist eine **Copyleft License**.

**Übung 2**
- Wer ein GPL-lizenziertes Programm verändert und weiterverteilt, muss den vollständigen Source Code der veränderten Version unter denselben Lizenzbedingungen zugänglich machen.
- Der Fachbegriff dafür lautet **Copyleft**.

**Übung 3**
- Copyleft (GPL) verpflichtet dazu, abgeleitete Werke unter derselben Lizenz und mit offenem Source Code weiterzugeben. Permissive Licenses (BSD/MIT) erlauben es dagegen, abgeleitete Werke – auch als proprietäre, closed-source Software – frei weiterzuverbreiten, ohne den Quellcode offenlegen zu müssen.
- Beispiel: Der **FreeBSD-Kernel** oder Komponenten wie **libpng** stehen unter einer BSD-artigen bzw. permissiven Lizenz.

**Übung 4**
- Typische Kategorien: **Webbrowser** (z. B. Firefox) und **Office-Anwendungen** (z. B. LibreOffice). Weitere mögliche Antworten: E-Mail-Clients, Grafik-/Multimedia-Anwendungen.
- Die Lizenz bestimmt, was Anwender mit der Software tun dürfen (nutzen, verändern, weiterverteilen) und ob z. B. Support- oder Haftungsbedingungen gelten – relevant für private wie auch kommerzielle Nutzung.

**Übung 5**
- Ein Software Repository stellt eine zentrale, kuratierte Quelle bereit, über die FOSS-Pakete gefunden, geprüft und installiert werden können; es ist damit ein zentraler Bestandteil des Verteilungs- und Update-Mechanismus im Open-Source-Ecosystem.
- Ein offizielles Distributions-Repository wird vom Distributions-Team geprüft und signiert, während Drittanbieterquellen (third-party repositories) nicht denselben Qualitäts- und Sicherheitsprüfungen unterliegen.

**Übung 6**
- Creative Commons wurde für kreative Inhalte (Texte, Bilder, Musik, Dokumentation) entwickelt und enthält keine Regelungen zu Themen wie Patenten oder Kompilierung/Distribution von ausführbarem Code, wie sie Software-Lizenzen (GPL, BSD, MIT) benötigen.
- **CC0** verzichtet vollständig auf Urheberrechte (Public Domain-artig, keine Bedingungen), während **CC BY-SA** eine Namensnennung (Attribution) verlangt und abgeleitete Werke unter derselben Lizenz weitergegeben werden müssen (Share-Alike, vergleichbar mit Copyleft-Prinzip).

</details>