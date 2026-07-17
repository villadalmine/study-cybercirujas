# 2.1 Command Line Basics

## Einführung

Die **Shell** ist das wichtigste Werkzeug für die Arbeit mit Linux. Sie ist ein Programm, das Befehle vom Benutzer entgegennimmt, sie interpretiert und an das Betriebssystem weitergibt. Die auf Linux-Systemen am weitesten verbreitete Shell ist die **Bash** (*Bourne Again Shell*), die Standard-Shell der meisten Distributionen. Andere Shells sind z. B. **zsh**, **ksh** oder **dash** — die Grundprinzipien sind bei allen ähnlich.

Der Zugang zur Shell erfolgt über einen **Terminal-Emulator** (z. B. GNOME Terminal, Konsole) oder über eine textbasierte Konsole. Nach dem Start zeigt die Shell einen **Prompt** an, der signalisiert, dass sie auf Eingaben wartet:

```
tux@laptop:~$
```

Typische Bestandteile des Prompts: Benutzername (`tux`), Hostname (`laptop`), aktuelles Verzeichnis (`~` steht für das *Home Directory*) und ein Symbol: `$` für normale Benutzer, `#` für den Benutzer **root**.

Welche Shell gerade läuft, verrät die Variable `SHELL`:

```
$ echo $SHELL
/bin/bash
```

---

## Aufbau einer Befehlszeile

Eine Befehlszeile folgt fast immer demselben Muster:

```
befehl [Optionen] [Argumente]
```

- **Befehl (command):** das auszuführende Programm oder ein in die Shell eingebautes Kommando (*shell builtin*).
- **Optionen (options):** verändern das Verhalten des Befehls. Kurzform mit einem Bindestrich (`-l`), Langform mit zwei Bindestrichen (`--all`).
- **Argumente (arguments):** die Objekte, auf die der Befehl wirkt, z. B. Dateien oder Verzeichnisse.

Beispiel:

```
$ ls -l /etc/hostname
-rw-r--r-- 1 root root 7 Mär 12 10:04 /etc/hostname
```

Hier ist `ls` der Befehl, `-l` die Option (ausführliche Liste) und `/etc/hostname` das Argument.

Kurzoptionen lassen sich kombinieren: `ls -la` entspricht `ls -l -a`. Die Elemente der Befehlszeile werden durch Leerzeichen getrennt; die Shell zerlegt die Eingabe an diesen Leerzeichen in einzelne **Wörter** (*word splitting*) — das ist später beim Thema *Quoting* wichtig.

### Befehlstypen: intern vs. extern

Ein Befehl kann ein eigenständiges Programm auf der Festplatte sein (**external command**) oder direkt in der Shell eingebaut (**builtin**). Der Befehl `type` zeigt, worum es sich handelt:

```
$ type echo
echo is a shell builtin
$ type ls
ls is aliased to `ls --color=auto'
$ type cp
cp is /usr/bin/cp
```

Wie das Beispiel zeigt, kann ein Befehl auch ein **Alias** sein — eine benutzerdefinierte Abkürzung, z. B.:

```
$ alias ll='ls -l'
$ ll /tmp
```

Mehrere Befehle lassen sich mit `;` in einer Zeile nacheinander ausführen:

```
$ cd /tmp ; ls
```

---

## Wichtige Grundbefehle

### echo — Text ausgeben

`echo` gibt seine Argumente auf der Standardausgabe aus und ist besonders nützlich, um den Inhalt von Variablen anzuzeigen:

```
$ echo Hallo Welt
Hallo Welt
$ echo $USER
tux
```

### pwd, cd — Navigation

```
$ pwd
/home/tux
$ cd /var/log
$ pwd
/var/log
$ cd          # ohne Argument: zurück ins Home Directory
```

### history — Befehlsverlauf

Die Shell speichert eingegebene Befehle im Verlauf (bei der Bash in der Datei `~/.bash_history`). Der Befehl `history` listet sie auf:

```
$ history
  481  pwd
  482  cd /var/log
  483  ls -l
```

Nützliche Techniken:

- `!!` — den letzten Befehl wiederholen.
- `!483` — den Befehl mit der Nummer 483 erneut ausführen.
- **Pfeiltasten ↑/↓** — durch den Verlauf blättern.
- **Ctrl+R** — interaktiv im Verlauf suchen (*reverse search*).

Die **Tab-Vervollständigung** (*tab completion*) ergänzt Befehls- und Dateinamen automatisch: `ls /etc/host` + `Tab` schlägt z. B. `hostname` und `hosts` vor. Das spart Tipparbeit und vermeidet Tippfehler.

---

## Variablen

Die Shell kennt zwei Arten von Variablen:

1. **Shell-Variablen (lokale Variablen):** existieren nur in der aktuellen Shell.
2. **Umgebungsvariablen (environment variables):** werden an alle Programme vererbt, die aus dieser Shell gestartet werden.

### Variablen setzen und lesen

Eine Variable wird mit `NAME=Wert` gesetzt — **ohne Leerzeichen** um das `=`:

```
$ greeting="Hallo Welt"
$ echo $greeting
Hallo Welt
```

Beim Lesen wird dem Namen ein `$` vorangestellt. Konventionell schreibt man Umgebungsvariablen in GROSSBUCHSTABEN, eigene Shell-Variablen gerne klein.

### export — Variablen an Kindprozesse weitergeben

Eine normale Shell-Variable ist für gestartete Programme unsichtbar. Mit `export` wird sie zur Umgebungsvariable:

```
$ mycolor=blue
$ bash                 # neue Shell starten (Kindprozess)
$ echo $mycolor
                       # leer — die Variable wurde nicht vererbt
$ exit
$ export mycolor
$ bash
$ echo $mycolor
blue
```

Setzen und Exportieren in einem Schritt: `export EDITOR=nano`

Weitere nützliche Befehle:

- `env` — alle Umgebungsvariablen anzeigen.
- `unset NAME` — eine Variable löschen.

Wichtige vordefinierte Umgebungsvariablen:

| Variable | Bedeutung |
|----------|-----------|
| `HOME` | Home Directory des Benutzers |
| `USER` | Benutzername |
| `SHELL` | Standard-Shell des Benutzers |
| `PWD` | aktuelles Verzeichnis |
| `LANG` | Sprach- und Regionseinstellung (*locale*) |
| `PATH` | Suchpfad für ausführbare Programme |

### Die Variable PATH

`PATH` enthält eine durch `:` getrennte Liste von Verzeichnissen, in denen die Shell nach externen Befehlen sucht:

```
$ echo $PATH
/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin
```

Tippt man `cp`, durchsucht die Shell diese Verzeichnisse der Reihe nach und führt den ersten Treffer aus (`/usr/bin/cp`). Liegt ein Programm **nicht** in einem `PATH`-Verzeichnis, muss man den Pfad angeben — z. B. `./meinskript.sh` für eine Datei im aktuellen Verzeichnis.

Ein Verzeichnis zum Suchpfad hinzufügen:

```
$ export PATH=$PATH:/home/tux/bin
```

Der alte Wert (`$PATH`) bleibt erhalten, das neue Verzeichnis wird angehängt. Die Änderung gilt nur für die aktuelle Sitzung; dauerhaft wird sie erst durch einen Eintrag in einer Startdatei wie `~/.bashrc`.

---

## Quoting

Die Shell interpretiert bestimmte Zeichen besonders, bevor sie den Befehl ausführt: Leerzeichen trennen Wörter, `$` leitet Variablen ein, `*` und `?` sind Platzhalter (*globbing*), etc. **Quoting** steuert, welche dieser Interpretationen stattfinden.

### Doppelte Anführungszeichen `"…"`

Unterdrücken *word splitting* und *globbing*, aber **Variablen werden weiterhin ersetzt** (*variable expansion*):

```
$ name=Tux
$ echo "Hallo $name, wie geht's?"
Hallo Tux, wie geht's?
```

Ohne Quotes würde ein Dateiname mit Leerzeichen als mehrere Argumente interpretiert:

```
$ touch "Meine Notizen.txt"    # eine Datei
$ touch Meine Notizen.txt      # zwei Dateien: "Meine" und "Notizen.txt"
```

### Einfache Anführungszeichen `'…'`

Unterdrücken **jede** Interpretation — auch Variablen werden nicht ersetzt:

```
$ echo '$name kostet $5'
$name kostet $5
$ echo "$name kostet $5"
Tux kostet
```

Im zweiten Beispiel versucht die Shell, `$5` als Variable zu ersetzen (sie ist leer) — deshalb einfache Quotes verwenden, wenn `$` wörtlich gemeint ist.

### Backslash `\` — einzelne Zeichen schützen

Der **escape character** `\` hebt die Sonderbedeutung genau des folgenden Zeichens auf:

```
$ echo Der Preis ist \$5
Der Preis ist $5
$ touch Meine\ Notizen.txt
```

### Merkregel

| Quoting | Word Splitting | Globbing (`*`, `?`) | Variablen (`$`) |
|---------|:---:|:---:|:---:|
| ohne | ja | ja | ja |
| `"…"` | nein | nein | **ja** |
| `'…'` | nein | nein | nein |
| `\x` | schützt nur das eine Zeichen | | |

Faustregel: Variablen fast immer in doppelte Quotes setzen (`"$var"`), damit Werte mit Leerzeichen nicht auseinandergerissen werden; einfache Quotes, wenn gar nichts interpretiert werden soll.

---

## Zusammenfassung

- Die **Shell** (meist **Bash**) nimmt Befehle entgegen; der **Prompt** zeigt Bereitschaft an (`$` normaler Benutzer, `#` root).
- Befehlszeilen bestehen aus **Befehl, Optionen und Argumenten**; `type` zeigt, ob ein Befehl *builtin*, *alias* oder externes Programm ist.
- `history`, Pfeiltasten, `Ctrl+R` und die **Tab-Vervollständigung** beschleunigen die Arbeit.
- **Variablen** werden mit `NAME=Wert` gesetzt und mit `$NAME` gelesen; `export` macht sie für Kindprozesse sichtbar; `PATH` bestimmt, wo die Shell Programme sucht.
- **Quoting**: `"…"` erlaubt Variablenersetzung, `'…'` unterdrückt alles, `\` schützt ein einzelnes Zeichen.

---

## Referenzen

- LPI Learning Materials, Thema 2.1 „Command Line Basics": https://learning.lpi.org/en/learning-materials/010-160/2/2.1/
- GNU Bash Reference Manual (offizielle Dokumentation): https://www.gnu.org/software/bash/manual/bash.html
- GNU Bash Manual — Kapitel „Quoting": https://www.gnu.org/software/bash/manual/html_node/Quoting.html
- GNU Coreutils Manual (`echo`, `pwd` u. a.): https://www.gnu.org/software/coreutils/manual/coreutils.html
- Prüfungsziele LPI Linux Essentials 010-160 (Version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/