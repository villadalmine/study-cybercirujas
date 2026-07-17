# 2.4 Creating, Moving and Deleting Files

## Einführung

Im Linux-Filesystem sind das Erstellen, Kopieren, Verschieben und Löschen von Dateien und Verzeichnissen tägliche Aufgaben. Anders als in grafischen Dateimanagern arbeitet man auf der Shell mit einer kleinen Gruppe von Kommandozeilen-Tools, die jeweils eine klar abgegrenzte Aufgabe erfüllen. Dieses Thema behandelt die Kernbefehle `touch`, `mkdir`, `rmdir`, `cp`, `mv` und `rm`, dazu einfache Wildcards (`*`, `?`) sowie die grundlegenden Archivierungs- und Kompressionswerkzeuge `tar`, `gzip`, `bzip2` und `xz`.

## Dateien erstellen: `touch`

`touch` legt eine leere Datei an, falls sie noch nicht existiert. Existiert die Datei bereits, wird lediglich ihr *modification timestamp* (mtime) auf die aktuelle Zeit gesetzt, ohne den Inhalt zu verändern.

```console
$ touch notes.txt
$ ls -l notes.txt
-rw-r--r-- 1 alice alice 0 Jul 12 10:00 notes.txt
```

Mehrere Dateien lassen sich in einem Aufruf erstellen:

```console
$ touch file1.txt file2.txt file3.txt
```

Ein häufig genutzter Anwendungsfall ist es, den Timestamp gezielt zu aktualisieren, ohne den Inhalt anzufassen, z. B. um ein Build-System zu einem erneuten Kompilieren zu bewegen:

```console
$ touch -t 202601010900 report.txt
```

## Verzeichnisse erstellen: `mkdir`

`mkdir` (*make directory*) erstellt ein neues, leeres Verzeichnis.

```console
$ mkdir projects
$ ls -ld projects
drwxr-xr-x 2 alice alice 4096 Jul 12 10:05 projects
```

Ohne weitere Optionen schlägt `mkdir` fehl, wenn übergeordnete Verzeichnisse fehlen:

```console
$ mkdir projects/2026/reports
mkdir: cannot create directory 'projects/2026/reports': No such file or directory
```

Mit der Option `-p` (*parents*) werden alle notwendigen übergeordneten Verzeichnisse automatisch mit angelegt, und ein bereits existierendes Zielverzeichnis führt nicht zu einem Fehler:

```console
$ mkdir -p projects/2026/reports
$ ls -R projects
projects:
2026

projects/2026:
reports
```

## Verzeichnisse löschen: `rmdir`

`rmdir` (*remove directory*) entfernt ausschließlich **leere** Verzeichnisse. Enthält das Verzeichnis noch Dateien oder Unterverzeichnisse, verweigert `rmdir` die Aktion:

```console
$ rmdir projects/2026/reports
$ rmdir projects
rmdir: failed to remove 'projects': Directory not empty
```

## Kopieren: `cp`

`cp` (*copy*) dupliziert Dateien oder Verzeichnisse.

```console
$ cp notes.txt notes_backup.txt
$ ls
notes.txt  notes_backup.txt
```

Beim Kopieren mehrerer Dateien in ein Zielverzeichnis muss dieses bereits existieren:

```console
$ cp file1.txt file2.txt projects/
```

Um ganze Verzeichnisbäume zu kopieren, ist die Option `-r` bzw. `-R` (*recursive*) erforderlich:

```console
$ cp -r projects projects_copy
```

Weitere nützliche Optionen:

| Option | Bedeutung |
|---|---|
| `-i` | *interactive* – fragt vor dem Überschreiben nach |
| `-v` | *verbose* – zeigt jede kopierte Datei an |
| `-p` | erhält Berechtigungen, Eigentümer und Timestamps |

```console
$ cp -i notes.txt notes_backup.txt
cp: overwrite 'notes_backup.txt'? y
```

## Verschieben und Umbenennen: `mv`

`mv` (*move*) verschiebt Dateien oder Verzeichnisse und wird zugleich zum Umbenennen verwendet – Linux kennt keinen eigenen `rename`-Befehl für die Shell.

Umbenennen (Quelle und Ziel liegen im selben Verzeichnis):

```console
$ mv notes.txt todo.txt
```

Verschieben in ein anderes Verzeichnis:

```console
$ mv todo.txt projects/
```

Im Gegensatz zu `cp` benötigt `mv` bei Verzeichnissen keine `-r`-Option, da der Verzeichnisinhalt nicht dupliziert, sondern lediglich der Verzeichniseintrag verschoben wird:

```console
$ mv projects archive
```

## Löschen: `rm`

`rm` (*remove*) löscht Dateien unwiderruflich – es gibt standardmäßig **keinen Papierkorb**.

```console
$ rm notes_backup.txt
```

Um Verzeichnisse samt Inhalt zu löschen, ist `-r` (*recursive*) notwendig:

```console
$ rm -r archive
```

Die Option `-f` (*force*) unterdrückt Rückfragen und Fehlermeldungen zu nicht existierenden Dateien; in Kombination `-rf` entfernt sie rekursiv und ohne Nachfrage – dies sollte mit besonderer Vorsicht verwendet werden, da es keine Bestätigung und keine Wiederherstellung gibt:

```console
$ rm -rf temp_dir
```

Zur Sicherheit empfiehlt sich vor dem tatsächlichen Löschen die Option `-i` (*interactive*):

```console
$ rm -i important.txt
rm: remove regular file 'important.txt'? n
```

## Einfache Wildcards (Globbing): `*` und `?`

Die Shell selbst (nicht die einzelnen Befehle) expandiert Wildcard-Muster, bevor der Befehl ausgeführt wird – dieser Vorgang heißt *globbing*.

- `*` steht für eine beliebige Zeichenkette (auch leer)
- `?` steht für genau ein beliebiges Zeichen

```console
$ ls
report1.txt  report2.txt  report10.txt  summary.log

$ ls report*.txt
report1.txt  report10.txt  report2.txt

$ ls report?.txt
report1.txt  report2.txt
```

Wildcards funktionieren mit jedem Befehl, der Dateinamen als Argumente akzeptiert:

```console
$ rm report*.txt
$ ls
summary.log
```

## Archivierung: `tar`

`tar` (*tape archive*) fasst mehrere Dateien und Verzeichnisse in einer einzigen Archivdatei zusammen, komprimiert dabei aber standardmäßig nicht.

Archiv erstellen (`-c` create, `-f` file, `-v` verbose):

```console
$ tar -cvf projects.tar projects/
projects/
projects/2026/
projects/2026/reports/
```

Archivinhalt anzeigen (`-t` list):

```console
$ tar -tf projects.tar
```

Archiv entpacken (`-x` extract):

```console
$ tar -xvf projects.tar
```

## Kompression: `gzip`, `bzip2`, `xz`

Diese Werkzeuge komprimieren einzelne Dateien und ersetzen sie standardmäßig durch die komprimierte Version:

```console
$ gzip report.txt
$ ls
report.txt.gz

$ gunzip report.txt.gz
$ ls
report.txt
```

`bzip2` und `xz` funktionieren analog, erreichen aber unterschiedliche Kompressionsraten und -geschwindigkeiten (allgemein: `gzip` am schnellsten, `xz` mit der besten Kompressionsrate, `bzip2` dazwischen):

```console
$ bzip2 report.txt      # erzeugt report.txt.bz2
$ xz report.txt         # erzeugt report.txt.xz
```

In der Praxis werden `tar` und Kompression häufig kombiniert, indem `tar` die Kompression direkt aufruft:

| Option | Kompression | Dateiendung |
|---|---|---|
| `-z` | gzip | `.tar.gz` / `.tgz` |
| `-j` | bzip2 | `.tar.bz2` |
| `-J` | xz | `.tar.xz` |

```console
$ tar -czvf projects.tar.gz projects/
$ tar -xzvf projects.tar.gz
```

## Zusammenfassung

| Befehl | Zweck |
|---|---|
| `touch` | Datei erstellen / Timestamp aktualisieren |
| `mkdir [-p]` | Verzeichnis(se) erstellen |
| `rmdir` | Leeres Verzeichnis löschen |
| `cp [-r]` | Dateien/Verzeichnisse kopieren |
| `mv` | Verschieben oder Umbenennen |
| `rm [-r] [-f]` | Dateien/Verzeichnisse löschen |
| `tar [-c/-x/-t]` | Archive erstellen/entpacken/auflisten |
| `gzip` / `bzip2` / `xz` | Kompression einzelner Dateien |

## Referenzen

- LPI Learning Materials, Topic 2.4 – Creating, Moving and Deleting Files: https://learning.lpi.org/en/learning-materials/010-160/2/2.4/
- GNU Coreutils Manual (cp, mv, rm, mkdir, rmdir, touch): https://www.gnu.org/software/coreutils/manual/coreutils.html
- GNU Tar Manual: https://www.gnu.org/software/tar/manual/tar.html
- man7.org Linux man-pages (tar, gzip, bzip2, xz): https://man7.org/linux/man-pages/