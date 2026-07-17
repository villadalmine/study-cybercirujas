# Thema 4.2: Understanding Computer Hardware — Guided Exercises

*Referenz: https://learning.lpi.org/en/learning-materials/010-160/4/4.2/*

## Übung 1: CPU-Informationen ermitteln

1. Öffne ein Terminal.
2. Führe folgenden Befehl aus, um Rohdaten zur CPU aus dem `/proc`-Filesystem zu lesen:
   ```
   less /proc/cpuinfo
   ```
3. Notiere die Werte der Felder `model name`, `cpu cores` und `flags`.
4. Verlasse `less` mit `q` und führe anschließend das komfortablere Tool aus:
   ```
   lscpu
   ```
5. Vergleiche die Ausgabe von `lscpu` (z. B. `CPU(s)`, `Thread(s) per core`, `Architecture`) mit den Werten aus Schritt 3.

**Verständnisfragen:**
- Welcher Unterschied besteht zwischen der Anzahl der Einträge in `/proc/cpuinfo` und dem Wert `CPU(s)` bei `lscpu`, wenn dein System mehrere Cores oder Hyper-Threading hat?
- Warum liest `lscpu` seine Daten letztlich aus derselben Quelle wie `cat /proc/cpuinfo`, präsentiert sie aber anders?

---

## Übung 2: PCI-Geräte auflisten

1. Führe aus:
   ```
   lspci
   ```
2. Suche in der Ausgabe eine Zeile, die eine Grafikkarte (`VGA compatible controller`) oder einen Netzwerk-Controller (`Ethernet controller`) beschreibt.
3. Führe den Befehl erneut mit mehr Details aus:
   ```
   lspci -v
   ```
4. Identifiziere bei deinem Netzwerk- oder Grafik-Controller, welches Kernel-Modul (`Kernel driver in use`) aktuell dafür geladen ist.
5. Führe `lspci -nn` aus und notiere die Vendor-ID und Device-ID (Format `[xxxx:xxxx]`) desselben Geräts.

**Verständnisfragen:**
- Wofür steht PCI, und welche Art von Hardware wird typischerweise über den PCI-Bus (bzw. PCIe) angebunden?
- Wozu dienen Vendor-ID und Device-ID, die `lspci -nn` anzeigt?

---

## Übung 3: USB-Geräte auflisten

1. Stecke, falls verfügbar, ein USB-Gerät ein (z. B. einen USB-Stick oder eine Maus).
2. Führe aus:
   ```
   lsusb
   ```
3. Identifiziere die neue Zeile, die durch das Einstecken hinzugekommen ist. Notiere die Bus- und Device-Nummer (`Bus 00X Device 00Y`).
4. Führe für dieses Gerät die Detailansicht aus (Bus- und Device-Nummer aus Schritt 3 einsetzen):
   ```
   lsusb -v -s 00X:00Y
   ```
5. Suche in der Ausgabe nach `bcdUSB`, um die unterstützte USB-Version zu ermitteln.

**Verständnisfragen:**
- Woran erkennst du in der `lsusb`-Ausgabe, welcher Hersteller (Vendor) ein bestimmtes USB-Gerät produziert hat?
- Welchen praktischen Nutzen hat `lsusb` bei der Fehlersuche, wenn ein angeschlossenes USB-Gerät vom System nicht erkannt wird?

---

## Übung 4: Kernel-Module für Hardware-Treiber

1. Zeige die aktuell geladenen Kernel-Module an:
   ```
   lsmod
   ```
2. Wähle aus der Liste ein Modul aus, das zu einer Netzwerkkarte, einem Sound-Chip oder einer Grafikkarte gehört (z. B. `e1000e`, `snd_hda_intel`).
3. Zeige Detailinformationen zu diesem Modul an (Modulname aus Schritt 2 einsetzen):
   ```
   modinfo <modulname>
   ```
4. Notiere die Felder `description`, `author` und `depends` aus der Ausgabe.
5. Prüfe mit folgendem Befehl, ob es zusätzliche Module gibt, von denen dein gewähltes Modul abhängt, und ob diese ebenfalls geladen sind:
   ```
   lsmod | grep <modulname>
   ```

**Verständnisfragen:**
- Was ist der Unterschied zwischen einem Kernel-Modul und der physischen Hardware-Komponente, die es ansteuert?
- Warum kann ein Hardware-Gerät vom System zwar physisch erkannt (z. B. in `lspci`), aber trotzdem nicht funktionsfähig sein?

---

## Übung 5: Boot- und Hardware-Meldungen prüfen

1. Führe aus:
   ```
   dmesg | less
   ```
2. Suche (mit `/` innerhalb von `less`) nach dem Begriff `usb`, um Meldungen zu USB-Geräten zu finden.
3. Suche anschließend nach `eth` oder `wlan`, um Meldungen zur Netzwerkkarte zu finden.
4. Verlasse `less` und filtere gezielt nach Speicher-bezogenen Meldungen:
   ```
   dmesg | grep -i memory
   ```
5. Vergleiche die Zeitstempel (in eckigen Klammern, z. B. `[    2.345678]`) der gefundenen Meldungen mit dem Bootvorgang deines Systems.

**Verständnisfragen:**
- Woher stammen die Meldungen, die `dmesg` anzeigt, und warum eignen sie sich besonders gut zur Diagnose von Hardware-Erkennungsproblemen direkt nach dem Booten?
- Was bedeutet ein Zeitstempel nahe `[0.000000]` in der `dmesg`-Ausgabe?

---

## Übung 6: Arbeitsspeicher prüfen

1. Führe aus:
   ```
   free -h
   ```
2. Notiere die Werte für `total`, `used`, `free` und `available` in der Zeile `Mem:`.
3. Prüfe, ob dein System Swap-Speicher konfiguriert hat, anhand der Zeile `Swap:`.
4. Führe zusätzlich aus, um die Rohwerte in Kilobytes zu sehen:
   ```
   cat /proc/meminfo | head -5
   ```
5. Vergleiche `MemTotal` aus `/proc/meminfo` mit dem `total`-Wert von `free -h`.

**Verständnisfragen:**
- Welchen Unterschied gibt es zwischen `free` und `available` in der Ausgabe von `free`?
- Wozu dient Swap-Speicher, und woher kommt dieser physisch (welche Hardware-Komponente wird dafür genutzt)?

---

## Übung 7: Interrupts, I/O-Ports und DMA

1. Zeige die aktuell zugewiesenen Hardware-Interrupts an:
   ```
   cat /proc/interrupts
   ```
2. Identifiziere eine Zeile, die zu deiner Netzwerkkarte oder einem USB-Controller gehört, und notiere die IRQ-Nummer (erste Spalte).
3. Zeige die reservierten I/O-Port-Bereiche an:
   ```
   cat /proc/ioports
   ```
4. Zeige die aktiven DMA-Kanäle an:
   ```
   cat /proc/dma
   ```
5. Vergleiche, ob dieselbe Hardware-Komponente in mehr als einer dieser drei Dateien auftaucht (z. B. Netzwerkkarte in `/proc/interrupts` und `/proc/ioports`).

**Verständnisfragen:**
- Wozu dient ein Interrupt (IRQ), und was passiert, wenn zwei Geräte denselben Interrupt ohne Sharing-Unterstützung beanspruchen?
- Was ist DMA (Direct Memory Access), und welchen Vorteil bietet es gegenüber einem Datentransfer, der vollständig über die CPU läuft?

---

<details>
<summary><strong>Lösungen</strong></summary>

**Übung 1:**
- `/proc/cpuinfo` listet einen Eintrag pro logischer CPU (also pro Thread bzw. Core), während `lscpu` unter `CPU(s)` bereits die aggregierte Gesamtzahl anzeigt und zusätzlich in `Thread(s) per core` und `Core(s) per socket` aufschlüsselt.
- `lscpu` parst und formatiert dieselben Kernel-Daten aus `/proc/cpuinfo` (und `sysfs`) nur benutzerfreundlicher, liest also keine andere Datenquelle.

**Übung 2:**
- PCI (Peripheral Component Interconnect, inkl. moderner PCIe-Variante) ist der interne Bus, über den Erweiterungskarten wie Grafikkarten, Netzwerkkarten, Sound-Chips und Controller mit dem Mainboard kommunizieren.
- Vendor-ID und Device-ID identifizieren Hersteller und exaktes Gerätemodell eindeutig und werden vom Kernel genutzt, um automatisch den passenden Treiber (Kernel-Modul) zu laden.

**Übung 3:**
- Am Feld für den Herstellernamen bzw. an der Vendor-ID (vierstelliger Hex-Code vor der Device-ID) in der `lsusb`-Ausgabe, z. B. `ID 046d:c52b Logitech, Inc.`.
- `lsusb` zeigt, ob das Gerät auf USB-Bus-Ebene überhaupt erkannt wurde; erscheint es nicht, liegt ein Hardware-/Kabel-/Port-Problem vor, erscheint es aber ohne funktionierenden Treiber, liegt das Problem eher auf Kernel-Modul-Ebene.

**Übung 4:**
- Das Kernel-Modul ist die Software (der Treiber), die im laufenden Kernel geladen wird, um mit der physischen Hardware-Komponente zu kommunizieren; die Hardware existiert unabhängig davon, ob ein passendes Modul geladen ist.
- Weil die Hardware zwar vom Bus (PCI/USB) elektrisch/logisch erkannt wird, aber kein passendes bzw. kompatibles Kernel-Modul geladen ist oder das Modul fehlkonfiguriert ist.

**Übung 5:**
- `dmesg` liest den Kernel-Ringpuffer (kernel ring buffer), in den der Kernel alle Meldungen inklusive Hardware-Erkennung während des Bootens schreibt; dadurch lassen sich Erkennungsprobleme direkt ab dem Zeitpunkt der Initialisierung nachvollziehen.
- Ein Zeitstempel nahe `[0.000000]` bedeutet, dass die Meldung sehr früh im Bootvorgang erzeugt wurde, meist noch während der Kernel-Initialisierung vor dem Start des Userspace.

**Übung 6:**
- `free` zeigt komplett ungenutzten Speicher; `available` schätzt zusätzlich, wie viel Speicher für neue Anwendungen bereitstünde, ohne Swapping auszulösen, da es auch reclaimable Caches/Buffers mit einbezieht.
- Swap-Speicher dient als Erweiterung des RAM auf einem langsameren Speichermedium (klassischerweise eine Festplatten-Partition oder Datei, physisch also auf HDD/SSD), auf das der Kernel bei Speicherdruck ausgelagerte Speicherseiten schreibt.

**Übung 7:**
- Ein IRQ signalisiert der CPU, dass ein Hardware-Gerät Aufmerksamkeit benötigt (z. B. eingehende Netzwerkdaten). Ohne IRQ-Sharing-Unterstützung kann ein Konflikt zwischen zwei Geräten auf demselben Interrupt zu Fehlfunktionen oder nicht erkannter Hardware führen; moderne Systeme (PCI/PCIe) unterstützen IRQ-Sharing jedoch standardmäßig.
- DMA erlaubt Geräten, Daten direkt mit dem Arbeitsspeicher auszutauschen, ohne dass jedes einzelne Datenwort über die CPU kopiert werden muss; das entlastet die CPU und erhöht den Datendurchsatz, besonders bei Festplatten- und Netzwerk-Controllern.

</details>