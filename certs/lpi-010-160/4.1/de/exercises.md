# Übungen zu Thema 4.1 – Choosing an Operating System

*LPI Linux Essentials (010-160, v1.6) – Gewichtung: 1*

---

## Übung 1: Kernel und Distribution unterscheiden

1. Öffne ein Terminal auf deinem Linux-System.
2. Lass dir die Kernel-Version anzeigen:
   ```bash
   uname -a
   ```
3. Lass dir die Distributions-Informationen anzeigen:
   ```bash
   cat /etc/os-release
   ```
4. Vergleiche die beiden Ausgaben: Notiere dir, welche Zeile den **Kernel** beschreibt und welche die **Distribution**.

**Verständnisfragen:**
- Was ist der Unterschied zwischen dem Linux-Kernel und einer Linux-Distribution wie Ubuntu, Fedora oder openSUSE?
- Warum können zwei unterschiedliche Distributionen (z. B. Debian und Fedora) denselben Kernel verwenden, sich aber im täglichen Gebrauch stark unterscheiden?

---

## Übung 2: Den Paketmanager der eigenen Distribution identifizieren

1. Prüfe, ob dein System ein Debian-basiertes Paketformat verwendet:
   ```bash
   dpkg --version 2>/dev/null && echo "Debian-basiert (dpkg/apt)"
   ```
2. Prüfe, ob dein System ein RPM-basiertes Paketformat verwendet:
   ```bash
   rpm --version 2>/dev/null && echo "RPM-basiert (rpm/dnf/zypper)"
   ```
3. Ordne dein System einer der beiden Familien zu und notiere den zugehörigen High-Level-Paketmanager (z. B. `apt` bei Debian/Ubuntu, `dnf` bei Fedora/RHEL/AlmaLinux/Rocky Linux, `zypper` bei openSUSE).

**Verständnisfragen:**
- Zu welcher Paketfamilie gehören Debian und Ubuntu, und zu welcher gehören Fedora, RHEL, AlmaLinux, Rocky Linux und openSUSE?
- Warum ist die Wahl der Distribution auch eine Wahl des Paketmanagement-Systems?

---

## Übung 3: Open Source vs. Closed Source Betriebssysteme gegenüberstellen

1. Erstelle eine Textdatei `os_vergleich.txt`.
2. Trage in Stichpunkten je drei Beispiele ein für:
   - Open-Source-Betriebssysteme (z. B. Linux-Distributionen, BSD-Varianten)
   - Closed-Source-Betriebssysteme (z. B. Windows, macOS)
3. Notiere zu jedem Beispiel, ob der Quellcode frei einsehbar/veränderbar ist oder nicht.

**Verständnisfragen:**
- Was bedeutet "Open Source" konkret in Bezug auf den Zugriff auf den Quellcode?
- Nenne einen praktischen Vorteil, den Open-Source-Betriebssysteme für Unternehmen oder Entwickler bieten können.

---

## Übung 4: Client-, Server- und Mobile-Betriebssysteme unterscheiden

1. Liste in einer weiteren Textdatei `os_kategorien.txt` folgende Kategorien auf:
   - Desktop/Client OS
   - Server OS
   - Mobile OS
2. Ordne jeder Kategorie mindestens ein Beispiel-Betriebssystem zu (z. B. Ubuntu Desktop, RHEL Server, Android).
3. Überlege für jede Kategorie eine typische Aufgabe, für die dieses Betriebssystem eingesetzt wird.

**Verständnisfragen:**
- Warum wird auf einem Server häufig eine andere Distribution oder Konfiguration eingesetzt als auf einem Desktop-Rechner?
- Ist Android ein eigenständiges Betriebssystem oder eine Linux-Distribution? Begründe deine Antwort.

---

## Übung 5: Virtualisierung und Live-Medien erkunden

1. Prüfe, ob dein Prozessor Virtualisierungs-Erweiterungen unterstützt:
   ```bash
   lscpu | grep -i virtualization
   ```
2. Prüfe, ob dein aktuelles System selbst in einer virtuellen Maschine oder einem Container läuft:
   ```bash
   systemd-detect-virt
   ```
3. Überlege, wie ein **Live-Medium** (z. B. ein bootfähiger USB-Stick mit Ubuntu) genutzt werden könnte, um eine Distribution auszuprobieren, ohne sie zu installieren.

**Verständnisfragen:**
- Was ist der Unterschied zwischen einer virtuellen Maschine (VM) und einem Container in Bezug auf das Betriebssystem?
- Welchen praktischen Vorteil bietet ein Live-Medium, wenn man eine neue Distribution testen möchte?

---

## Übung 6: Embedded-Systeme mit Linux

1. Recherchiere (z. B. über eine Suchmaschine oder Dokumentation) mindestens zwei Geräte-Kategorien, in denen Linux als Embedded-Betriebssystem eingesetzt wird (z. B. Router, Smart-TVs, IoT-Geräte).
2. Notiere, welche schlanke Linux-Variante häufig in Embedded-Systemen zum Einsatz kommt (Stichwort: minimalistische Toolsammlungen für eingebettete Systeme).

**Verständnisfragen:**
- Warum eignet sich Linux besonders gut für Embedded-Systeme mit begrenzten Ressourcen?
- Nenne ein Beispiel für ein Alltagsgerät, das vermutlich mit einem Linux-basierten Embedded-System läuft.

---

<details>
<summary>Lösungen</summary>

**Übung 1**
- Der **Kernel** ist die Kernkomponente, die Hardware, Prozesse, Speicher und Systemaufrufe verwaltet (in `uname -a` sichtbar, z. B. `Linux 6.x`). Die **Distribution** ist ein komplettes Software-Paket rund um den Kernel: Paketmanager, Desktop-Umgebung, Standardsoftware, Konfigurationswerkzeuge (in `/etc/os-release` sichtbar, z. B. `NAME="Ubuntu"`).
- Weil der Kernel bei den meisten Distributionen derselbe (oder eine sehr ähnliche Version) ist – die Distributionen unterscheiden sich aber in Paketauswahl, Update-Zyklus, Zielgruppe, Standard-Tools und Philosophie (z. B. Debian: Stabilität, Fedora: aktuelle Software).

**Übung 2**
- Debian und Ubuntu gehören zur **dpkg/apt**-Familie. Fedora, RHEL, AlmaLinux, Rocky Linux und openSUSE gehören zur **RPM**-Familie (dnf bzw. zypper).
- Weil das Paketformat und der Paketmanager an die Distribution gebunden sind – Pakete aus der einen Familie lassen sich nicht direkt in der anderen installieren, was Kompatibilität und Softwareverfügbarkeit beeinflusst.

**Übung 3**
- Open Source bedeutet, dass der Quellcode öffentlich einsehbar, veränderbar und weiterverteilbar ist, meist unter einer Lizenz wie der GPL.
- Beispiel: Unternehmen können das Betriebssystem an eigene Bedürfnisse anpassen, Sicherheitslücken selbst prüfen oder von der Community entwickelte Verbesserungen kostenlos nutzen.

**Übung 4**
- Server-Betriebssysteme sind meist auf Stabilität, Sicherheit, Ressourcenschonung (oft ohne grafische Oberfläche) und Langzeit-Support ausgelegt, während Desktop-Systeme auf Benutzerfreundlichkeit und aktuelle Software für Endanwender fokussiert sind.
- Android basiert auf dem Linux-Kernel, gilt aber als eigenständiges Betriebssystem (mit eigenem Anwendungsrahmen, z. B. keine klassische GNU-Toolchain), nicht als klassische Linux-Distribution im Sinne von Debian oder Fedora.

**Übung 5**
- Eine VM virtualisiert komplette Hardware und führt einen eigenen, vollständigen Kernel aus; ein Container teilt sich den Kernel des Host-Systems und isoliert nur Prozesse, Dateisystem und Netzwerk auf Betriebssystemebene – dadurch ist ein Container leichtgewichtiger und schneller startbar.
- Ein Live-Medium erlaubt es, eine Distribution direkt von USB/DVD zu starten und auszuprobieren, ohne etwas auf der Festplatte zu installieren oder das bestehende System zu verändern.

**Übung 6**
- Linux ist quelloffen, modular und lässt sich stark verschlanken (nur benötigte Kernel-Module und Programme einbinden), außerdem ist es lizenzkostenfrei und auf viele Prozessorarchitekturen portiert – ideal für Geräte mit wenig Speicher/Rechenleistung.
- Beispiele: WLAN-Router, Smart-TVs, Set-Top-Boxen, viele IoT-Geräte (Smart-Home-Hubs) laufen häufig auf einem angepassten, minimalen Linux-System.

</details>

---

**Quelle (Referenz, kein wörtliches Zitat):** [LPI Learning Materials – 010-160, Topic 4.1](https://learning.lpi.org/en/learning-materials/010-160/4/4.1/)