# 3.2 Searching and Extracting Data from Files

## Überblick

Bei der Arbeit auf der Kommandozeile muss man ständig Text durchsuchen, filtern und umformen: Logdateien nach Fehlern durchsuchen, Spalten aus einer CSV-Datei extrahieren, Duplikate aus einer Liste entfernen. Linux stellt dafür eine Reihe kleiner, spezialisierter Tools bereit, die man über **pipes** (`|`) miteinander kombiniert – das klassische Unix-Prinzip "ein Werkzeug, eine Aufgabe". Die wichtigsten Werkzeuge für dieses Thema sind `grep`, `cut`, `sort`, `uniq`, `wc`, `tr`, `head` und `tail`, dazu **regular expressions (regex)** als gemeinsame Sprache zur Mustererkennung.

## grep: Textmuster in Dateien suchen

`grep` (*global regular expression print*) durchsucht Zeilen einer Datei oder eines Streams nach einem Muster und gibt passende Zeilen aus.

```
$ grep "root" /etc/passwd
root:x:0:0:root:/root:/bin/bash
```

Wichtige Optionen:

| Option | Bedeutung |
|---|---|
| `-i` | case-insensitive (Groß-/Kleinschreibung ignorieren) |
| `-v` | invertiert die Suche (Zeilen, die NICHT passen) |
| `-n` | zeigt die Zeilennummer an |
| `-c` | zählt nur die Treffer |
| `-r` / `-R` | rekursiv durch ein Verzeichnis |
| `-l` | zeigt nur die Dateinamen mit Treffern |
| `-w` | matcht nur ganze Wörter |

```
$ grep -i "error" logfile.txt
$ grep -v "^#" /etc/ssh/sshd_config
$ grep -n "bash" /etc/passwd
1:root:x:0:0:root:/root:/bin/bash
$ grep -rl "TODO" ~/projects/
```

## Regular Expressions (Basic Regex)

`grep` versteht standardmäßig **Basic Regular Expressions (BRE)**. Die wichtigsten Metazeichen:

| Zeichen | Bedeutung |
|---|---|
| `.` | ein beliebiges Zeichen |
| `*` | null oder mehr Wiederholungen des vorherigen Zeichens |
| `^` | Anfang der Zeile |
| `$` | Ende der Zeile |
| `[...]` | eine Zeichenklasse, z. B. `[Rr]` |
| `[^...]` | Negation einer Zeichenklasse |
| `\` | escaped ein Sonderzeichen (z. B. `\.` für einen literalen Punkt) |

```
$ grep "^root" /etc/passwd
root:x:0:0:root:/root:/bin/bash

$ grep "bash$" /etc/passwd

$ grep "r.ot" /etc/passwd

$ grep "[Rr]oot" /etc/passwd

$ grep "^[^#]" /etc/hosts
```

Für **Extended Regular Expressions (ERE)** mit `+`, `?`, `|` und `()` ohne escaping nutzt man `grep -E` (entspricht `egrep`):

```
$ grep -E "^(root|admin):" /etc/passwd
```

## Redirection und Pipes

Bevor man Tools kombiniert, ist das Verständnis von **stdin**, **stdout** und Pipes wichtig:

| Operator | Bedeutung |
|---|---|
| `>` | Standardausgabe in eine Datei umleiten (überschreibt) |
| `>>` | Standardausgabe an eine Datei anhängen |
| `<` | Standardeingabe aus einer Datei lesen |
| `\|` | Standardausgabe des einen Befehls als Standardeingabe des nächsten |

```
$ grep "error" logfile.txt > errors.txt
$ grep "error" logfile.txt >> all_errors.txt
$ sort < names.txt
$ cat access.log | grep "GET"
```

## head und tail: Anfang und Ende einer Datei

```
$ head -n 5 /var/log/syslog
$ tail -n 20 /var/log/syslog
```

Mit `tail -f` (*follow*) verfolgt man eine wachsende Datei live, z. B. beim Debuggen eines laufenden Dienstes:

```
$ tail -f /var/log/syslog
```

## sort: Zeilen sortieren

```
$ sort names.txt
$ sort -r names.txt          # umgekehrte Reihenfolge
$ sort -n numbers.txt        # numerisch statt lexikografisch
$ sort -t: -k3 -n /etc/passwd   # nach 3. Feld (UID), Trenner ":"
```

Wichtige Optionen: `-n` (numerisch), `-r` (reverse), `-k` (Sortierfeld/Spalte), `-t` (Feldtrenner), `-u` (unique, entfernt Duplikate direkt beim Sortieren).

## uniq: Duplikate entfernen oder zählen

`uniq` erkennt nur **aufeinanderfolgende** doppelte Zeilen – daher fast immer nach `sort` verwendet:

```
$ sort access.log | uniq -c | sort -rn | head -5
    152 192.168.1.10
     89 192.168.1.23
     47 192.168.1.5
```

Optionen: `-c` (Anzahl der Vorkommen), `-d` (nur Duplikate anzeigen), `-u` (nur eindeutige Zeilen anzeigen).

## wc: Zeilen, Wörter, Zeichen zählen

```
$ wc -l /etc/passwd
45 /etc/passwd

$ wc -w file.txt
$ cat access.log | grep "404" | wc -l
```

Optionen: `-l` (Zeilen), `-w` (Wörter), `-c` (Bytes), `-m` (Zeichen).

## cut: Spalten extrahieren

```
$ cut -d: -f1 /etc/passwd
root
daemon
bin
...

$ cut -d: -f1,7 /etc/passwd
root:/bin/bash
daemon:/usr/sbin/nologin
...

$ cut -c1-5 file.txt
```

`-d` legt den Feldtrenner fest (Standard: Tab), `-f` wählt die Felder, `-c` wählt Zeichenpositionen.

## tr: Zeichen übersetzen oder löschen

`tr` liest ausschließlich von **stdin** und arbeitet zeichenweise, nicht zeilenweise:

```
$ echo "Hello World" | tr 'a-z' 'A-Z'
HELLO WORLD

$ echo "hello    world" | tr -s ' '
hello world

$ cat dos_file.txt | tr -d '\r' > unix_file.txt
```

Optionen: `-d` (Zeichen löschen), `-s` (aufeinanderfolgende Wiederholungen zu einem Zeichen zusammenfassen).

## Praxisbeispiel: eine Pipeline kombinieren

Die häufigsten Client-IPs aus einem Zugriffslog ermitteln:

```
$ cat access.log | grep "GET" | cut -d' ' -f1 | sort | uniq -c | sort -rn | head -5
    342 203.0.113.7
    201 198.51.100.4
    ...
```

Diese Kombination zeigt das Kernprinzip von Linux Essentials: kleine Werkzeuge, jedes mit einer klaren Aufgabe, über `|` zu einer Verarbeitungskette verbunden.

## Referenzen

- LPI Learning Materials – Topic 3.2: https://learning.lpi.org/en/learning-materials/010-160/3/3.2/
- GNU grep Manual: https://www.gnu.org/software/grep/manual/grep.html
- GNU Coreutils Manual (sort, uniq, wc, cut, tr, head, tail): https://www.gnu.org/software/coreutils/manual/coreutils.html
- grep(1) man page: https://man7.org/linux/man-pages/man1/grep.1.html
- sort(1) man page: https://man7.org/linux/man-pages/man1/sort.1.html
- cut(1) man page: https://man7.org/linux/man-pages/man1/cut.1.html
- tr(1) man page: https://man7.org/linux/man-pages/man1/tr.1.html