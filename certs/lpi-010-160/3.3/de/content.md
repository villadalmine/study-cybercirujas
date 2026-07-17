# 3.3 Turning Commands into a Script

## Einführung

Wer regelmäßig mit der Kommandozeile arbeitet, stellt schnell fest, dass sich bestimmte Abfolgen von Befehlen ständig wiederholen: Log-Dateien aufräumen, Backups erstellen, Systeminformationen sammeln. Anstatt dieselben Befehle immer wieder von Hand einzutippen, kann man sie in eine Datei schreiben und als **Shell Script** ausführen. Ein Script ist nichts anderes als eine Textdatei, die eine Folge von Befehlen enthält, die die Shell nacheinander abarbeitet.

Shell Scripts sind ein zentrales Werkzeug der Automatisierung unter Linux. Dieses Thema hat mit dem Gewicht 4 das höchste Einzelgewicht im Examen 010-160 — die Konzepte hier sollten Sie sicher beherrschen: **Shebang**, Ausführbarkeit mit `chmod`, **Variables**, **Arguments**, **Exit Status**, Bedingungen mit `if` und Schleifen mit `for`.

---

## Text Editors: Scripts erstellen

Ein Script ist eine reine Textdatei. Um sie zu erstellen, braucht man einen **Text Editor** — keine Textverarbeitung wie LibreOffice Writer, denn diese speichert Formatierungen, die die Shell nicht versteht.

Die zwei wichtigsten Editoren auf der Kommandozeile:

### nano

`nano` ist einsteigerfreundlich und auf den meisten Distributionen vorinstalliert:

```
$ nano meinscript.sh
```

Die wichtigsten Tastenkombinationen werden am unteren Bildschirmrand angezeigt (`^` steht für die `Ctrl`-Taste):

| Tastenkombination | Funktion |
|---|---|
| `Ctrl+O` | Datei speichern (*Write Out*) |
| `Ctrl+X` | Editor beenden |
| `Ctrl+K` | Zeile ausschneiden |
| `Ctrl+U` | Zeile einfügen |
| `Ctrl+W` | Suchen (*Where Is*) |

### vi / vim

`vi` (bzw. der verbreitete Nachfolger `vim`) ist auf praktisch jedem Unix-artigen System vorhanden und daher für Administratoren unverzichtbar. `vi` arbeitet mit **Modi**:

- **Command Mode**: Tasten sind Befehle (Navigation, Löschen, Kopieren). Startmodus.
- **Insert Mode**: Text eingeben — erreichbar mit `i`, zurück mit `Esc`.

Die wichtigsten Befehle im Command Mode:

| Befehl | Funktion |
|---|---|
| `i` | In den Insert Mode wechseln |
| `Esc` | Zurück in den Command Mode |
| `:w` | Speichern (*write*) |
| `:q` | Beenden (*quit*) |
| `:wq` | Speichern und beenden |
| `:q!` | Beenden ohne zu speichern |
| `dd` | Zeile löschen |

Für das Examen genügt es, beide Editoren zu kennen und Dateien damit erstellen, ändern und speichern zu können.

---

## Vom Befehl zum Script

### Das erste Script

Angenommen, Sie führen regelmäßig diese Befehle aus, um sich einen Überblick über das System zu verschaffen:

```
$ date
$ df -h /
$ free -h
```

Schreiben Sie diese Befehle in eine Datei `sysinfo.sh`:

```bash
#!/bin/bash

# sysinfo.sh - zeigt grundlegende Systeminformationen
date
df -h /
free -h
```

Zwei Dinge fallen auf:

1. Die erste Zeile `#!/bin/bash` — der **Shebang** (siehe unten).
2. Die Zeile mit `#` — ein **Comment**. Alles nach `#` wird von der Shell ignoriert. Kommentare dokumentieren, was ein Script tut, und sind gute Praxis.

Die Endung `.sh` ist eine Konvention zur besseren Lesbarkeit — Linux selbst benötigt keine Dateiendung, um ein Script auszuführen.

### Der Shebang: `#!/bin/bash`

Die erste Zeile eines Scripts beginnt idealerweise mit den Zeichen `#!` (gesprochen *shebang* oder *hash-bang*), gefolgt vom absoluten Pfad des **Interpreters**, der das Script ausführen soll:

```bash
#!/bin/bash
```

Wenn der Kernel eine Datei mit Shebang ausführt, startet er den angegebenen Interpreter und übergibt ihm das Script. So kann ein Script auch andere Interpreter nutzen:

```bash
#!/bin/sh        # POSIX-Shell (oft ein Link auf dash oder bash)
#!/usr/bin/python3   # Python-Script
#!/usr/bin/perl      # Perl-Script
```

Der Unterschied zwischen `/bin/sh` und `/bin/bash`: `/bin/sh` steht für die minimale, POSIX-kompatible **Bourne Shell**. Auf vielen Distributionen ist `/bin/sh` ein symbolischer Link — unter Debian/Ubuntu z. B. auf `dash`, unter anderen Systemen auf `bash`. Scripts mit `#!/bin/sh` sollten nur portable Standard-Syntax verwenden; Scripts mit `#!/bin/bash` dürfen alle Bash-Erweiterungen nutzen.

### Script ausführbar machen: `chmod`

Eine neu erstellte Textdatei hat keine **Execute Permission**:

```
$ ls -l sysinfo.sh
-rw-r--r-- 1 tux tux 82 Jul 14 10:15 sysinfo.sh
```

Mit `chmod` fügen Sie das Ausführungsrecht hinzu (`+x` = *execute* für alle):

```
$ chmod +x sysinfo.sh
$ ls -l sysinfo.sh
-rwxr-xr-x 1 tux tux 82 Jul 14 10:15 sysinfo.sh
```

### Script ausführen

Jetzt lässt sich das Script starten. Wichtig: Das aktuelle Verzeichnis ist aus Sicherheitsgründen **nicht** im Suchpfad `PATH` enthalten, deshalb muss der Pfad angegeben werden — `./` steht für das aktuelle Verzeichnis:

```
$ ./sysinfo.sh
Tue Jul 14 10:16:03 CEST 2026
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2        50G   18G   30G  38% /
               total        used        free      shared  buff/cache   available
Mem:            15Gi       4,2Gi       6,1Gi       310Mi       5,1Gi        11Gi
```

Alternativ kann man das Script als Argument an die Shell übergeben — dann ist weder Shebang noch Execute Permission nötig, weil explizit ein Interpreter gestartet wird:

```
$ bash sysinfo.sh
```

Soll ein Script von überall ohne Pfadangabe aufrufbar sein, legt man es in ein Verzeichnis, das in der Variable `PATH` enthalten ist (z. B. `/usr/local/bin` oder `~/bin`).

---

## Ausgabe mit `echo`

Der Befehl `echo` gibt Text auf der Standardausgabe aus und ist das wichtigste Werkzeug, um Scripts "sprechen" zu lassen:

```bash
#!/bin/bash
echo "Systembericht wird erstellt..."
echo    # eine leere Zeile ausgeben
echo "Fertig."
```

Nützliche Optionen:

- `echo -n` — unterdrückt den abschließenden Zeilenumbruch (*newline*).

```
$ echo -n "Kein Umbruch: "
Kein Umbruch: $
```

---

## Variables

Eine **Variable** speichert einen Wert unter einem Namen. Zuweisung erfolgt mit `=` — **ohne Leerzeichen** um das Gleichheitszeichen. Der Zugriff erfolgt mit vorangestelltem `$`:

```bash
#!/bin/bash
NAME="Tux"
ZIEL=/tmp/backup

echo "Hallo, $NAME!"
echo "Backup-Ziel: $ZIEL"
```

```
$ ./variablen.sh
Hallo, Tux!
Backup-Ziel: /tmp/backup
```

Regeln für Variablennamen: Buchstaben, Ziffern und Unterstrich; nicht mit einer Ziffer beginnen; Groß-/Kleinschreibung wird unterschieden. Konventionell schreibt man eigene Konstanten groß.

Häufige Fehlerquelle — Leerzeichen bei der Zuweisung:

```
$ NAME = "Tux"
NAME: command not found
```

### Command Substitution

Die Ausgabe eines Befehls kann in einer Variable gespeichert werden — mit `$(befehl)`:

```bash
#!/bin/bash
HEUTE=$(date +%F)
KERNEL=$(uname -r)
echo "Bericht vom $HEUTE, Kernel $KERNEL"
```

```
$ ./bericht.sh
Bericht vom 2026-07-14, Kernel 6.15.4-200.fc42.x86_64
```

### Quoting

- **Doppelte Anführungszeichen** (`"..."`): Variablen werden ersetzt.
- **Einfache Anführungszeichen** (`'...'`): alles wird wörtlich genommen, keine Ersetzung.

```
$ NAME="Tux"
$ echo "Hallo $NAME"
Hallo Tux
$ echo 'Hallo $NAME'
Hallo $NAME
```

### Eingaben lesen mit `read`

`read` liest eine Zeile von der Standardeingabe in eine Variable:

```bash
#!/bin/bash
echo -n "Wie heißen Sie? "
read ANTWORT
echo "Willkommen, $ANTWORT!"
```

```
$ ./frage.sh
Wie heißen Sie? Ada
Willkommen, Ada!
```

---

## Arguments: Positional Parameters

Scripts können beim Aufruf **Arguments** entgegennehmen. Innerhalb des Scripts stehen sie als **Positional Parameters** zur Verfügung:

| Parameter | Bedeutung |
|---|---|
| `$0` | Name des Scripts selbst |
| `$1`, `$2`, … `$9` | erstes, zweites, … neuntes Argument |
| `$#` | Anzahl der übergebenen Argumente |
| `$@` | alle Argumente (einzeln) |
| `$*` | alle Argumente (als eine Zeichenkette) |

Beispiel `gruss.sh`:

```bash
#!/bin/bash
echo "Script:            $0"
echo "Erstes Argument:   $1"
echo "Zweites Argument:  $2"
echo "Anzahl Argumente:  $#"
echo "Alle Argumente:    $@"
```

```
$ ./gruss.sh Hallo Welt
Script:            ./gruss.sh
Erstes Argument:   Hallo
Zweites Argument:  Welt
Anzahl Argumente:  2
Alle Argumente:    Hallo Welt
```

Argumente machen Scripts wiederverwendbar: Statt einen Dateinamen fest ins Script zu schreiben, übergibt man ihn beim Aufruf.

---

## Exit Status

Jeder Befehl unter Linux liefert beim Beenden einen **Exit Status** (auch *return code*) zurück — eine Zahl zwischen 0 und 255:

- **0** bedeutet **Erfolg**.
- **Jeder andere Wert** bedeutet einen **Fehler** (die genaue Bedeutung ist befehlsabhängig).

Die Spezialvariable `$?` enthält den Exit Status des zuletzt ausgeführten Befehls:

```
$ ls /etc/hostname
/etc/hostname
$ echo $?
0
$ ls /gibtesnicht
ls: cannot access '/gibtesnicht': No such file or directory
$ echo $?
2
```

Achtung: `$?` wird nach *jedem* Befehl neu gesetzt — auch nach `echo` selbst. Wer den Wert später braucht, speichert ihn in einer Variable.

In eigenen Scripts setzt man den Exit Status mit dem Befehl `exit`:

```bash
#!/bin/bash
if [ $# -eq 0 ]; then
    echo "Fehler: kein Argument übergeben."
    exit 1
fi
echo "Verarbeite $1 ..."
exit 0
```

Ohne explizites `exit` liefert das Script den Exit Status seines letzten Befehls zurück. Exit Codes sind die Grundlage für die Verkettung mit `&&` (nur bei Erfolg weitermachen) und `||` (nur bei Fehler weitermachen):

```
$ mkdir /tmp/daten && echo "Verzeichnis angelegt"
Verzeichnis angelegt
```

---

## Bedingungen: `if` und `test`

Mit `if` führt ein Script Befehle nur unter bestimmten Bedingungen aus. Die Bedingung ist selbst ein Befehl — entscheidend ist dessen Exit Status (0 = wahr):

```bash
if bedingung; then
    # Befehle bei Erfolg
else
    # Befehle bei Misserfolg
fi
```

Für Vergleiche verwendet man den Befehl `test` bzw. dessen verbreitete Schreibweise mit eckigen Klammern `[ ... ]` (die Leerzeichen um die Klammern sind Pflicht!). Wichtige Tests:

| Test | wahr, wenn … |
|---|---|
| `[ -f DATEI ]` | DATEI existiert und ist eine reguläre Datei |
| `[ -d PFAD ]` | PFAD existiert und ist ein Verzeichnis |
| `[ -x DATEI ]` | DATEI ist ausführbar |
| `[ "$A" = "$B" ]` | Zeichenketten sind gleich |
| `[ "$A" != "$B" ]` | Zeichenketten sind ungleich |
| `[ "$X" -eq "$Y" ]` | Zahlen sind gleich (*equal*) |
| `[ "$X" -ne "$Y" ]` | Zahlen sind ungleich (*not equal*) |
| `[ "$X" -lt "$Y" ]` | X kleiner als Y (*less than*) |
| `[ "$X" -gt "$Y" ]` | X größer als Y (*greater than*) |

Beispiel `check.sh`:

```bash
#!/bin/bash
DATEI="$1"

if [ -f "$DATEI" ]; then
    echo "$DATEI existiert."
else
    echo "$DATEI existiert nicht."
fi
```

```
$ ./check.sh /etc/passwd
/etc/passwd existiert.
$ ./check.sh /tmp/nix
/tmp/nix existiert nicht.
```

Gute Praxis: Variablen in Tests immer in doppelte Anführungszeichen setzen (`"$DATEI"`), damit leere Werte oder Leerzeichen im Inhalt keinen Syntaxfehler verursachen.

---

## Schleifen: `for`

Eine **for loop** wiederholt Befehle für jedes Element einer Liste:

```bash
#!/bin/bash
for FARBE in rot grün blau; do
    echo "Farbe: $FARBE"
done
```

```
$ ./farben.sh
Farbe: rot
Farbe: grün
Farbe: blau
```

Die Liste kann auch aus Dateinamen (per **Globbing**) oder aus einer Command Substitution stammen:

```bash
#!/bin/bash
# Größe aller .log-Dateien im aktuellen Verzeichnis anzeigen
for DATEI in *.log; do
    echo "Prüfe $DATEI:"
    du -h "$DATEI"
done
```

```
$ ./logcheck.sh
Prüfe app.log:
1,2M    app.log
Prüfe error.log:
16K     error.log
```

Zahlenbereiche erzeugt man mit der **Brace Expansion** `{start..ende}` oder mit `seq`:

```bash
#!/bin/bash
for I in {1..5}; do
    echo "Durchlauf $I"
done
```

```
$ ./zaehler.sh
Durchlauf 1
Durchlauf 2
Durchlauf 3
Durchlauf 4
Durchlauf 5
```

### Ausblick: `while`

Neben `for` kennt die Bash die **while loop**, die läuft, solange eine Bedingung wahr ist:

```bash
#!/bin/bash
I=1
while [ "$I" -le 3 ]; do
    echo "Runde $I"
    I=$((I + 1))
done
```

Die Schreibweise `$(( ... ))` ist die **Arithmetic Expansion** der Bash für Ganzzahlrechnung.

---

## Alles zusammen: ein komplettes Beispiel

Das folgende Script fasst alle Konzepte des Themas zusammen — Shebang, Comments, Arguments, Variables, Exit Status, `if` und `for`:

```bash
#!/bin/bash
# backupcheck.sh - prüft, ob Dateien existieren, und meldet das Ergebnis
# Aufruf: ./backupcheck.sh datei1 [datei2 ...]

if [ $# -eq 0 ]; then
    echo "Verwendung: $0 DATEI..."
    exit 1
fi

DATUM=$(date +%F)
echo "Prüfung am $DATUM"

FEHLER=0
for DATEI in "$@"; do
    if [ -f "$DATEI" ]; then
        echo "OK:      $DATEI"
    else
        echo "FEHLT:   $DATEI"
        FEHLER=$((FEHLER + 1))
    fi
done

if [ "$FEHLER" -gt 0 ]; then
    echo "$FEHLER Datei(en) fehlen."
    exit 1
fi

echo "Alle Dateien vorhanden."
exit 0
```

```
$ chmod +x backupcheck.sh
$ ./backupcheck.sh /etc/passwd /etc/nix /etc/hosts
Prüfung am 2026-07-14
OK:      /etc/passwd
FEHLT:   /etc/nix
OK:      /etc/hosts
1 Datei(en) fehlen.
$ echo $?
1
```

---

## Zusammenfassung

- Ein **Shell Script** ist eine Textdatei mit Befehlen, erstellt mit einem Editor wie `nano` oder `vi`.
- Der **Shebang** `#!/bin/bash` in der ersten Zeile legt den Interpreter fest; `/bin/sh` steht für die portable POSIX-Shell.
- Mit `chmod +x script.sh` wird das Script ausführbar, gestartet wird es mit `./script.sh`.
- `echo` gibt Text aus, `read` liest Eingaben, `#` leitet Kommentare ein.
- **Variables** werden mit `NAME=wert` (ohne Leerzeichen) gesetzt und mit `$NAME` gelesen; `$(befehl)` speichert Befehlsausgaben.
- **Arguments** erreichen das Script als `$1`, `$2`, …; `$#` zählt sie, `$@` liefert alle, `$0` ist der Scriptname.
- Der **Exit Status** (`$?`) meldet Erfolg (0) oder Fehler (≠ 0); mit `exit N` setzt ein Script ihn selbst.
- `if [ ... ]; then ... fi` prüft Bedingungen, `for VAR in LISTE; do ... done` wiederholt Befehle.

---

## Referenzen

- LPI Learning Materials, Thema 3.3 — Turning Commands into a Script: https://learning.lpi.org/en/learning-materials/010-160/3/3.3/
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- GNU Coreutils Manual (u. a. `echo`, `test`, `chmod`): https://www.gnu.org/software/coreutils/manual/coreutils.html
- Nano Editor — offizielle Dokumentation: https://www.nano-editor.org/docs.php
- Vim — offizielle Dokumentation: https://www.vim.org/docs.php
- LPI Exam Objectives, Linux Essentials 010-160 (Version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/