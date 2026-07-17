# 3.1 Archiving Files on the Command Line

## Archivierung vs. Kompression

Zwei Konzepte werden hier oft verwechselt, sind aber getrennt zu betrachten:

- **Archivierung** bündelt mehrere Dateien und Verzeichnisse (inklusive Metadaten wie Berechtigungen, Eigentümer, Zeitstempel) in eine einzige Datei. Die Struktur bleibt erhalten, die Größe ändert sich dabei kaum.
- **Kompression** reduziert die Größe von Daten durch mathematische Algorithmen, sagt aber nichts über die Struktur mehrerer Dateien aus.

Unter Linux ist `tar` das klassische Werkzeug für die Archivierung. Es wird meist mit einem Kompressionsprogramm wie `gzip`, `bzip2` oder `xz` kombiniert.

## tar – Tape Archive

`tar` ist das Standardwerkzeug, um ein oder mehrere Verzeichnisse in eine einzelne `.tar`-Datei zu packen. Der Name stammt historisch von "Tape Archive", da das Tool ursprünglich für Magnetbänder entwickelt wurde.

### Grundsyntax

```
tar [OPTIONEN] ARCHIVDATEI [DATEIEN/VERZEICHNISSE...]
```

### Wichtige Optionen

| Option | Bedeutung |
|---|---|
| `-c` | **c**reate – neues Archiv erstellen |
| `-x` | e**x**tract – Archiv entpacken |
| `-t` | **t**able of contents – Inhalt auflisten, ohne zu entpacken |
| `-v` | **v**erbose – Dateinamen während der Verarbeitung anzeigen |
| `-f` | **f**ile – gibt an, dass der nächste Parameter der Archivname ist (fast immer erforderlich) |
| `-z` | Kompression/Dekompression mit `gzip` |
| `-j` | Kompression/Dekompression mit `bzip2` |
| `-J` | Kompression/Dekompression mit `xz` |
| `-C` | in ein anderes Verzeichnis wechseln, bevor Dateien extrahiert werden |
| `--exclude=MUSTER` | bestimmte Dateien/Muster vom Archiv ausschließen |
| `-p` | Berechtigungen (Permissions) beim Entpacken beibehalten |

### Beispiel: Archiv erstellen

```
$ tar -cvf backup.tar dokumente/
dokumente/
dokumente/notizen.txt
dokumente/bericht.pdf
dokumente/rechnungen/
dokumente/rechnungen/2026-06.pdf
```

### Beispiel: Inhalt eines Archivs auflisten

```
$ tar -tvf backup.tar
drwxr-xr-x user/user       0 2026-07-01 10:00 dokumente/
-rw-r--r-- user/user    1523 2026-07-01 09:58 dokumente/notizen.txt
-rw-r--r-- user/user    8820 2026-07-01 09:59 dokumente/bericht.pdf
drwxr-xr-x user/user       0 2026-07-01 10:00 dokumente/rechnungen/
-rw-r--r-- user/user   44210 2026-06-30 14:12 dokumente/rechnungen/2026-06.pdf
```

Diese Auflistung ist wichtig, um vor dem Entpacken zu prüfen, ob das Archiv seine eigenen Inhalte in ein Unterverzeichnis packt oder die Dateien direkt ins aktuelle Verzeichnis extrahiert würde.

### Beispiel: Archiv entpacken

```
$ tar -xvf backup.tar
```

In ein bestimmtes Zielverzeichnis entpacken, ohne vorher hineinzuwechseln:

```
$ tar -xvf backup.tar -C /tmp/wiederherstellung/
```

### Komprimierte Archive erstellen

Die Kompressionsoption wird einfach mit den bekannten Buchstaben kombiniert:

```
$ tar -czvf backup.tar.gz dokumente/     # gzip
$ tar -cjvf backup.tar.bz2 dokumente/    # bzip2
$ tar -cJvf backup.tar.xz dokumente/     # xz
```

Modernes GNU `tar` erkennt beim Entpacken das Kompressionsformat automatisch anhand des Dateiinhalts, sodass `tar -xvf backup.tar.gz` auch ohne explizites `-z` funktioniert. Es ist trotzdem guter Stil, die Option explizit anzugeben.

### Datei-Endungen als Konvention

| Endung | Bedeutung |
|---|---|
| `.tar` | unkomprimiertes Archiv |
| `.tar.gz` / `.tgz` | mit gzip komprimiert |
| `.tar.bz2` / `.tbz2` | mit bzip2 komprimiert |
| `.tar.xz` / `.txz` | mit xz komprimiert |

## Kompressionswerkzeuge: gzip, bzip2, xz

Diese drei Programme komprimieren **einzelne** Dateien (nicht mehrere auf einmal wie `tar`). Sie ersetzen standardmäßig die Originaldatei durch die komprimierte Version.

| Werkzeug | Endung | Algorithmus | Eigenschaften |
|---|---|---|---|
| `gzip` / `gunzip` | `.gz` | DEFLATE | schnell, moderate Kompressionsrate |
| `bzip2` / `bunzip2` | `.bz2` | Burrows-Wheeler | langsamer, bessere Kompressionsrate als gzip |
| `xz` / `unxz` | `.xz` | LZMA2 | am langsamsten, beste Kompressionsrate |

### Beispiel

```
$ ls -lh bericht.log
-rw-r--r-- 1 user user 12M Jul 12 09:00 bericht.log

$ gzip bericht.log
$ ls -lh bericht.log.gz
-rw-r--r-- 1 user user 3.1M Jul 12 09:00 bericht.log.gz

$ gunzip bericht.log.gz
$ ls -lh bericht.log
-rw-r--r-- 1 user user  12M Jul 12 09:00 bericht.log
```

Um die Originaldatei zu behalten, wird die Option `-k` (keep) verwendet:

```
$ bzip2 -k bericht.log
$ ls
bericht.log  bericht.log.bz2
```

Der Kompressionsgrad lässt sich mit `-1` (schnell, wenig Kompression) bis `-9` (langsam, maximale Kompression) steuern:

```
$ xz -9 -k bericht.log
```

Um den Inhalt einer komprimierten Datei anzusehen, ohne sie zu entpacken, gibt es die Pendants `zcat`, `bzcat` und `xzcat`:

```
$ zcat bericht.log.gz | grep "ERROR"
```

## zip und unzip

Im Gegensatz zu `tar` archiviert `zip` **und** komprimiert gleichzeitig – ein einzelner Befehl reicht. Das Format ist besonders für den Austausch mit Windows-Systemen relevant, da es dort nativ unterstützt wird.

```
$ zip -r archiv.zip dokumente/
  adding: dokumente/ (stored 0%)
  adding: dokumente/notizen.txt (deflated 42%)

$ unzip archiv.zip
$ unzip -l archiv.zip     # Inhalt auflisten, ohne zu entpacken
```

## cpio

`cpio` ("copy in/out") ist ein weiteres klassisches Archivierungswerkzeug. Anders als `tar` erhält es die Liste der zu archivierenden Dateien **über die Standardeingabe** – typischerweise von `find` geliefert. Das macht es besonders flexibel für selektive Archive.

Die drei Betriebsmodi:

| Option | Modus |
|---|---|
| `-o` | copy-out – Archiv erstellen |
| `-i` | copy-in – Archiv entpacken |
| `-p` | pass-through – Dateien direkt in ein anderes Verzeichnis kopieren, ohne Zwischenarchiv |

### Beispiel: Archiv erstellen

```
$ find dokumente/ -print | cpio -ov > archiv.cpio
dokumente/
dokumente/notizen.txt
dokumente/bericht.pdf
234 blocks
```

### Beispiel: Archiv entpacken

```
$ cpio -idv < archiv.cpio
```

`-d` sorgt dafür, dass benötigte Verzeichnisse automatisch angelegt werden.

## dd

`dd` kopiert Daten Block für Block auf niedriger Ebene – nicht dateibasiert wie `tar` oder `cpio`, sondern byteweise. Es wird typischerweise verwendet, um komplette Datenträger, Partitionen oder Boot-Images zu duplizieren.

### Grundsyntax

```
dd if=QUELLE of=ZIEL [bs=BLOCKGRÖSSE] [status=progress]
```

- `if` (input file) – Quelle
- `of` (output file) – Ziel
- `bs` – Blockgröße pro Lese-/Schreibvorgang (Standard oft 512 Byte; größere Werte wie `4M` beschleunigen den Vorgang)

### Beispiel: Image einer Partition erstellen

```
$ sudo dd if=/dev/sdb1 of=partition.img bs=4M status=progress
1073741824 bytes (1.1 GB) copied, 12 s, 89.5 MB/s
```

**Vorsicht:** `dd` prüft nicht, ob das Ziel bereits Daten enthält – ein vertauschtes `if`/`of` kann eine ganze Festplatte unwiderruflich überschreiben. Vor jedem Einsatz sollte Quelle und Ziel doppelt geprüft werden.

## File Globbing bei der Archivierung

Beim Zusammenstellen von Archiven werden häufig Wildcards (Globbing-Muster) verwendet, um Dateien auszuwählen, statt jede einzeln aufzuzählen. Diese Muster werden von der Shell **vor** dem Aufruf von `tar` expandiert.

| Muster | Bedeutung |
|---|---|
| `*` | beliebig viele Zeichen |
| `?` | genau ein Zeichen |
| `[abc]` | eines der Zeichen a, b oder c |
| `[0-9]` | eine Ziffer |

```
$ tar -cvf logs.tar *.log
$ tar -cvf reports-2026.tar bericht-2026-[0-1][0-9].pdf
```

Da die Shell die Expansion übernimmt, sieht `tar` in Wirklichkeit bereits die vollständige Liste der passenden Dateinamen, nicht das Muster selbst.

## Referenzen

- LPI Learning Materials, Topic 3.1 – Archiving Files on the Command Line: https://learning.lpi.org/en/learning-materials/010-160/3/3.1/
- GNU tar Manual: https://www.gnu.org/software/tar/manual/tar.html
- GNU gzip Manual: https://www.gnu.org/software/gzip/manual/gzip.html
- bzip2 Homepage: https://sourceware.org/bzip2/
- XZ Utils: https://tukaani.org/xz/
- GNU cpio Manual: https://www.gnu.org/software/cpio/manual/cpio.html
- GNU Coreutils – dd Invocation: https://www.gnu.org/software/coreutils/manual/html_node/dd-invocation.html
- Info-ZIP (zip/unzip): https://infozip.sourceforge.net/