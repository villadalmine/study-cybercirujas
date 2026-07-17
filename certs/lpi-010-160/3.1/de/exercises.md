# Übungen: 3.1 Archiving Files on the Command Line

## Übung 1 – Ein tar-Archiv erstellen

1. Lege ein Arbeitsverzeichnis an und wechsle hinein:
   ```bash
   mkdir ~/archiv-uebung && cd ~/archiv-uebung
   ```
2. Erzeuge drei Testdateien:
   ```bash
   echo "Inhalt A" > datei1.txt
   echo "Inhalt B" > datei2.txt
   mkdir unterordner
   echo "Inhalt C" > unterordner/datei3.txt
   ```
3. Erstelle ein tar-Archiv aus allen Dateien im aktuellen Verzeichnis:
   ```bash
   tar cvf projekt.tar datei1.txt datei2.txt unterordner
   ```
4. Prüfe die Größe des erzeugten Archivs:
   ```bash
   ls -l projekt.tar
   ```

**Verständnisfragen**
- Wofür stehen die Optionen `c`, `v` und `f` im Befehl `tar cvf`?
- Was passiert, wenn man die Option `f` weglässt und stattdessen `tar cv projekt.tar ...` schreibt?
- Ist `projekt.tar` an sich schon komprimiert? Begründe kurz.

## Übung 2 – Archivinhalt auflisten, ohne zu extrahieren

1. Zeige den Inhalt des Archivs an, ohne die Dateien auf die Platte zu schreiben:
   ```bash
   tar tvf projekt.tar
   ```
2. Zähle, wie viele Einträge das Archiv enthält:
   ```bash
   tar tvf projekt.tar | wc -l
   ```

**Verständnisfragen**
- Welche einzelne Option von `tar` zeigt den Inhalt eines Archivs an, ohne ihn zu extrahieren?
- Woran erkennst du in der Ausgabe von `tar tvf`, ob ein Eintrag eine Datei oder ein Verzeichnis ist?

## Übung 3 – Archiv extrahieren

1. Lege ein separates Zielverzeichnis an:
   ```bash
   mkdir extrahiert && cd extrahiert
   ```
2. Extrahiere das gesamte Archiv dorthin:
   ```bash
   tar xvf ../projekt.tar
   ```
3. Kontrolliere die extrahierte Struktur:
   ```bash
   find . -type f
   ```
4. Extrahiere jetzt, zurück im Elternverzeichnis, nur eine einzelne Datei aus dem Archiv:
   ```bash
   cd ..
   tar xvf projekt.tar datei1.txt -C /tmp
   ```

**Verständnisfragen**
- Was bewirkt die Option `x` bei `tar`?
- Wozu dient die Option `-C` beim Extrahieren?
- Was passiert, wenn im Zielverzeichnis bereits eine Datei mit gleichem Namen existiert wie eine Datei im Archiv?

## Übung 4 – Komprimieren mit gzip

1. Komprimiere das vorhandene tar-Archiv mit gzip:
   ```bash
   gzip projekt.tar
   ```
2. Prüfe, welche Datei jetzt existiert:
   ```bash
   ls -l projekt.tar*
   ```
3. Dekomprimiere die Datei wieder, behalte dabei aber die `.gz`-Datei:
   ```bash
   gunzip -k projekt.tar.gz
   ```

**Verständnisfragen**
- Ändert `gzip` den Dateinamen? Wenn ja, wie?
- Wofür steht die Option `-k` bei `gunzip` (bzw. `gzip -dk`)?
- Ist `gzip` in der Lage, ein ganzes Verzeichnis direkt zu komprimieren, ohne vorher ein tar-Archiv zu erstellen?

## Übung 5 – bzip2 und xz im Vergleich

1. Erzeuge zwei Kopien des unkomprimierten Archivs für den Vergleich:
   ```bash
   tar cvf archiv-bz2.tar datei1.txt datei2.txt unterordner
   tar cvf archiv-xz.tar datei1.txt datei2.txt unterordner
   ```
2. Komprimiere eine Kopie mit bzip2 und die andere mit xz:
   ```bash
   bzip2 archiv-bz2.tar
   xz archiv-xz.tar
   ```
3. Vergleiche die resultierenden Dateigrößen:
   ```bash
   ls -l archiv-bz2.tar.bz2 archiv-xz.tar.xz
   ```

**Verständnisfragen**
- Welche Dateiendungen erzeugen `gzip`, `bzip2` und `xz` jeweils?
- Welches der drei Tools erzielt bei den meisten Dateien tendenziell die höchste Kompressionsrate, benötigt dafür aber mehr Rechenzeit?
- Mit welchem Befehl entpackst du eine `.tar.xz`-Datei wieder in ihre ursprüngliche `.tar`-Form?

## Übung 6 – Archivieren und Komprimieren in einem Schritt

1. Lege ein neues Testverzeichnis mit Inhalt an:
   ```bash
   mkdir daten && echo "Test" > daten/info.txt
   ```
2. Erstelle direkt ein gzip-komprimiertes tar-Archiv:
   ```bash
   tar czvf daten.tar.gz daten/
   ```
3. Erstelle direkt ein bzip2-komprimiertes tar-Archiv:
   ```bash
   tar cjvf daten.tar.bz2 daten/
   ```
4. Erstelle direkt ein xz-komprimiertes tar-Archiv:
   ```bash
   tar cJvf daten.tar.xz daten/
   ```
5. Extrahiere eines der Archive testweise in ein neues Verzeichnis:
   ```bash
   mkdir daten-restore
   tar xzvf daten.tar.gz -C daten-restore
   ```

**Verständnisfragen**
- Welche `tar`-Option steht für gzip, welche für bzip2 und welche für xz?
- Muss man beim Extrahieren mit `tar xvf datei.tar.gz` zwingend zusätzlich `-z` angeben, damit es funktioniert? Begründe.

## Übung 7 – Arbeiten mit zip und unzip

1. Erstelle ein zip-Archiv aus den beiden Textdateien:
   ```bash
   zip projekt.zip datei1.txt datei2.txt
   ```
2. Liste den Inhalt auf, ohne zu entpacken:
   ```bash
   unzip -l projekt.zip
   ```
3. Entpacke das Archiv in ein neues Verzeichnis:
   ```bash
   unzip projekt.zip -d zip-extrahiert
   ```

**Verständnisfragen**
- Welchen praktischen Vorteil hat `zip` gegenüber `tar` im Hinblick auf die Interoperabilität mit anderen Betriebssystemen (z. B. Windows)?
- Welchen Nachteil hat `zip` traditionell gegenüber `tar`, wenn es um Unix-Dateiberechtigungen, Eigentümer und symbolische Links geht?

## Übung 8 – cpio als alternative Archivierungsmethode

1. Erzeuge eine Liste aller `.txt`-Dateien und übergib sie an `cpio`, um ein Archiv zu erstellen:
   ```bash
   find . -maxdepth 1 -name "*.txt" | cpio -ov > projekt.cpio
   ```
2. Zeige den Inhalt des cpio-Archivs an:
   ```bash
   cpio -tv < projekt.cpio
   ```
3. Extrahiere das Archiv in ein neues Verzeichnis:
   ```bash
   mkdir cpio-extrahiert && cd cpio-extrahiert
   cpio -idv < ../projekt.cpio
   cd ..
   ```

**Verständnisfragen**
- Worin unterscheidet sich `cpio` grundlegend von `tar` bezüglich der Art, wie es seine Dateiliste erhält?
- Wofür stehen die Optionen `-o`, `-i`, `-t` und `-d` bei `cpio`?

---

## Lösungen

<details>
<summary>Antworten anzeigen</summary>

**Übung 1**
- `c` = create (neues Archiv anlegen), `v` = verbose (Dateinamen während der Verarbeitung anzeigen), `f` = file (gibt an, dass das nächste Argument der Archivname ist, statt z. B. eines Bandlaufwerks).
- Ohne `f` erwartet `tar` traditionell ein Bandlaufwerk als Ziel; moderne `tar`-Implementierungen geben meist eine Fehlermeldung aus, weil kein Archivname angegeben wurde.
- Nein, ein reines `tar`-Archiv ist nicht komprimiert – `tar` bündelt Dateien nur zu einem einzigen Container (daher der Begriff „Tape Archive“); die eigentliche Kompression übernehmen separate Tools wie `gzip`, `bzip2` oder `xz`.

**Übung 2**
- Die Option `t` (list contents) zeigt den Inhalt eines Archivs an, ohne etwas zu extrahieren.
- Verzeichniseinträge erkennt man am führenden `d` in der Dateityp-/Rechte-Spalte der Langauflistung (analog zu `ls -l`), Dateien am `-`.

**Übung 3**
- `x` (extract) entpackt die im Archiv enthaltenen Dateien in das aktuelle bzw. angegebene Verzeichnis.
- `-C` (change directory) weist `tar` an, vor dem Extrahieren in das angegebene Verzeichnis zu wechseln, statt in das aktuelle Arbeitsverzeichnis zu entpacken.
- Standardmäßig überschreibt `tar` vorhandene Dateien gleichen Namens ohne Rückfrage.

**Übung 4**
- Ja: `gzip` hängt die Endung `.gz` an und entfernt standardmäßig die unkomprimierte Originaldatei (aus `projekt.tar` wird `projekt.tar.gz`).
- `-k` (keep) sorgt dafür, dass die Originaldatei zusätzlich zur komprimierten/dekomprimierten Version erhalten bleibt.
- Nein, `gzip` komprimiert immer nur einzelne Dateien (einen Datenstrom); um ein ganzes Verzeichnis zu komprimieren, muss man es vorher mit `tar` zu einer einzigen Datei bündeln.

**Übung 5**
- `gzip` → `.gz`, `bzip2` → `.bz2`, `xz` → `.xz`.
- `xz` erzielt in der Regel die höchste Kompressionsrate, benötigt dafür aber deutlich mehr CPU-Zeit und Arbeitsspeicher als `gzip` oder `bzip2`.
- `unxz datei.tar.xz` (oder `xz -d datei.tar.xz`) entpackt die `.xz`-Kompression und liefert wieder `datei.tar`.

**Übung 6**
- `-z` steht für gzip, `-j` für bzip2, `-J` für xz.
- Nein, moderne `tar`-Versionen erkennen das Kompressionsformat beim Extrahieren automatisch anhand des Dateiinhalts bzw. der Endung, sodass `tar xvf datei.tar.gz` auch ohne explizites `-z` funktioniert. Für portablere Skripte gibt man die Option trotzdem meist explizit an.

**Übung 7**
- `zip`-Archive lassen sich nativ unter Windows und macOS öffnen, ohne dass zusätzliche Tools installiert werden müssen – ideal für den Austausch mit Nicht-Unix-Systemen.
- Traditionelle `zip`-Implementierungen speichern Unix-spezifische Metadaten wie Eigentümer, Gruppenzugehörigkeit, vollständige Zugriffsrechte und symbolische Links nicht zuverlässig, während `tar` diese Informationen vollständig bewahrt.

**Übung 8**
- `tar` durchsucht selbst die angegebenen Pfade nach Dateien; `cpio` erhält seine Dateiliste dagegen ausschließlich über die Standardeingabe (stdin), typischerweise von `find` oder `ls` geliefert.
- `-o` (create/output) erstellt ein Archiv aus den über stdin gelieferten Pfaden, `-i` (extract/input) liest ein Archiv von stdin und extrahiert es, `-t` (list) listet den Archivinhalt auf, `-d` (make directories) legt beim Extrahieren fehlende Zielverzeichnisse automatisch an.

</details>

---

**Quellen**
- https://learning.lpi.org/en/learning-materials/010-160/3/3.1/