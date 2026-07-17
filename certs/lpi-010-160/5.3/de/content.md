# 5.3 Managing File Permissions and Ownership

## Übersicht

Jede Datei und jedes Verzeichnis unter Linux gehört einem **owner** (Benutzer) und einer **group** und besitzt einen Satz von **permissions**, der festlegt, wer lesen, schreiben oder ausführen darf. Dieses Modell ist fundamental für die Sicherheit eines Linux-Systems: Ohne korrekt gesetzte Berechtigungen könnten beliebige Benutzer fremde Dateien lesen, verändern oder löschen.

## Das Berechtigungsmodell: user, group, other

Für jede Datei gibt es drei Kategorien von Berechtigten:

- **user (u)** – der Eigentümer der Datei
- **group (g)** – die Gruppe, der die Datei zugeordnet ist
- **other (o)** – alle übrigen Benutzer

Für jede dieser Kategorien existieren drei mögliche Rechte:

- **r (read)** – Datei lesen bzw. Verzeichnisinhalt auflisten
- **w (write)** – Datei verändern bzw. Einträge im Verzeichnis anlegen/löschen
- **x (execute)** – Datei ausführen bzw. in ein Verzeichnis wechseln (`cd`)

Bei Verzeichnissen bedeutet `x` also nicht "ausführen" im klassischen Sinn, sondern das Recht, das Verzeichnis zu betreten und auf Dateien darin zuzugreifen (sofern deren eigene Rechte das erlauben).

## Berechtigungen anzeigen: `ls -l`

```
$ ls -l notes.txt
-rw-r--r-- 1 anna dev 1024 Jul 10 09:15 notes.txt
```

Die erste Spalte lässt sich in vier Blöcke zerlegen:

```
-   rw-      r--      r--
^    ^        ^        ^
Typ  user     group    other
```

- **Typ**: `-` reguläre Datei, `d` Verzeichnis, `l` symbolischer Link
- **user**: `rw-` → owner darf lesen und schreiben, aber nicht ausführen
- **group**: `r--` → Gruppenmitglieder dürfen nur lesen
- **other**: `r--` → alle anderen dürfen nur lesen

Bei einem Verzeichnis sieht das etwa so aus:

```
$ ls -ld /home/anna/projects
drwxr-x--- 2 anna dev 4096 Jul 10 09:15 /home/anna/projects
```

Hier darf nur `anna` (rwx) das Verzeichnis vollständig nutzen, die Gruppe `dev` darf hineinschauen und wechseln (`r-x`), andere haben gar keinen Zugriff (`---`).

## Berechtigungen als Oktalzahl

Jedes Recht entspricht einem Bit-Wert:

| Recht | Wert |
|---|---|
| r | 4 |
| w | 2 |
| x | 1 |

Die drei Werte pro Kategorie werden addiert. So ergibt sich z. B. `rwxr-xr--`:

```
rwx = 4+2+1 = 7
r-x = 4+0+1 = 5
r-- = 4+0+0 = 4
→ 754
```

`644` entspricht also `rw-r--r--`, `755` entspricht `rwxr-xr-x`, `700` entspricht `rwx------`.

## Berechtigungen ändern: `chmod`

### Symbolische Notation

```
$ chmod g+w notes.txt      # Gruppe bekommt Schreibrecht
$ chmod o-r notes.txt      # Andere verlieren Leserecht
$ chmod u+x script.sh      # Eigentümer darf ausführen
$ chmod a+r shared.txt     # alle (a = all) bekommen Leserecht
$ chmod u=rw,g=r,o= file   # Rechte exakt setzen
```

Operatoren: `+` hinzufügen, `-` entfernen, `=` exakt setzen. Kategorien: `u`, `g`, `o`, `a`.

### Oktale Notation

```
$ chmod 644 notes.txt
$ ls -l notes.txt
-rw-r--r-- 1 anna dev 1024 Jul 10 09:20 notes.txt

$ chmod 755 script.sh
$ ls -l script.sh
-rwxr-xr-x 1 anna dev  512 Jul 10 09:22 script.sh
```

### Rekursiv anwenden

```
$ chmod -R 750 /home/anna/projects
```

`-R` wendet die Änderung auf alle Dateien und Unterverzeichnisse an – bei Verzeichnisbäumen mit gemischten Dateitypen sollte man vorsichtig sein, da dabei z. B. auch normalen Dateien das `x`-Bit gesetzt werden kann, wenn man versehentlich `755` statt einer differenzierten Vorgehensweise verwendet.

## Eigentümer und Gruppe ändern: `chown` und `chgrp`

```
$ chown bruno notes.txt              # Eigentümer ändern
$ chown bruno:staff notes.txt        # Eigentümer und Gruppe zugleich
$ chown :staff notes.txt             # nur die Gruppe ändern
$ chgrp staff notes.txt              # Gruppe ändern (Alternative zu chown :group)
```

```
$ ls -l notes.txt
-rw-r--r-- 1 bruno staff 1024 Jul 10 09:20 notes.txt
```

Auch `chown`/`chgrp` unterstützen `-R` für rekursive Änderungen:

```
$ chown -R bruno:staff /home/anna/projects
```

Nur `root` darf den Eigentümer einer Datei auf einen beliebigen anderen Benutzer ändern; normale Benutzer können höchstens die Gruppe wechseln, sofern sie selbst Mitglied der Zielgruppe sind.

## Standardrechte: `umask`

Wenn eine neue Datei oder ein neues Verzeichnis angelegt wird, vergibt der Kernel zunächst maximale Standardrechte (theoretisch `666` für Dateien, `777` für Verzeichnisse) und zieht davon die **umask** ab.

```
$ umask
0022
```

Bei einer `umask` von `022`:

- Neue Dateien: `666 - 022 = 644` → `rw-r--r--`
- Neue Verzeichnisse: `777 - 022 = 755` → `rwxr-xr-x`

```
$ umask 077
$ touch privat.txt
$ ls -l privat.txt
-rw------- 1 anna dev 0 Jul 10 09:30 privat.txt
```

`umask` ohne Argument zeigt den aktuellen Wert, `umask <wert>` setzt ihn für die aktuelle Shell-Sitzung. Dauerhafte Änderungen trägt man in Shell-Startdateien wie `~/.bashrc` ein.

## Spezielle Berechtigungen

Neben den Standardrechten gibt es drei besondere Bits:

### SUID (Set User ID)

Bei ausführbaren Dateien bewirkt SUID, dass das Programm mit den Rechten des **Eigentümers** läuft, unabhängig davon, wer es startet. Klassisches Beispiel: `passwd`, das kurzzeitig root-Rechte benötigt, um `/etc/shadow` zu schreiben.

```
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208 Mar  1 2024 /usr/bin/passwd
```

Das `s` anstelle des `x` im user-Block zeigt SUID an. Gesetzt wird es mit:

```
$ chmod u+s programm
$ chmod 4755 programm
```

Die führende `4` in der vierstelligen Oktalnotation steht für SUID.

### SGID (Set Group ID)

Bei ausführbaren Dateien analog zu SUID, aber mit der **Gruppe**. Bei Verzeichnissen hat SGID eine andere, sehr nützliche Wirkung: neu erstellte Dateien und Unterverzeichnisse erben automatisch die Gruppe des Verzeichnisses statt der primären Gruppe des Erstellers.

```
$ chmod g+s /srv/teamdir
$ chmod 2775 /srv/teamdir
$ ls -ld /srv/teamdir
drwxrwsr-x 2 anna dev 4096 Jul 10 09:35 /srv/teamdir
```

Das `s` im group-Block zeigt SGID an. Die führende `2` in der Oktalnotation steht für SGID.

### Sticky Bit

Bei Verzeichnissen sorgt das sticky bit dafür, dass nur der Eigentümer einer Datei (oder root) diese löschen oder umbenennen kann, selbst wenn andere Benutzer Schreibrecht auf das Verzeichnis haben. Typisches Beispiel ist `/tmp`.

```
$ ls -ld /tmp
drwxrwxrwt 14 root root 4096 Jul 10 08:00 /tmp
```

Das `t` am Ende zeigt das gesetzte sticky bit an (ein großes `T` würde bedeuten, dass das execute-Bit für "other" fehlt). Setzen:

```
$ chmod +t /srv/shared
$ chmod 1777 /srv/shared
```

Die führende `1` in der Oktalnotation steht für das sticky bit.

### Übersicht der führenden Ziffer

| Wert | Bit | Wirkung |
|---|---|---|
| 4 | SUID | Ausführung mit Rechten des Eigentümers |
| 2 | SGID | Ausführung mit Rechten der Gruppe / Vererbung der Gruppe bei Verzeichnissen |
| 1 | sticky | Löschen nur durch Eigentümer (bei Verzeichnissen) |

Diese Werte lassen sich kombinieren, z. B. `chmod 6755` setzt SUID und SGID gleichzeitig.

## Praxisbeispiel: typischer Workflow

```
$ touch report.sh
$ ls -l report.sh
-rw-r--r-- 1 anna dev 0 Jul 10 10:00 report.sh

$ chmod u+x report.sh
$ ls -l report.sh
-rwxr--r-- 1 anna dev 0 Jul 10 10:00 report.sh

$ chown anna:dev report.sh
$ chmod 750 report.sh
$ ls -l report.sh
-rwxr-x--- 1 anna dev 0 Jul 10 10:00 report.sh
```

Damit kann `anna` das Skript lesen, schreiben und ausführen, die Gruppe `dev` darf es lesen und ausführen, alle anderen haben keinen Zugriff.

## Referenzen

- LPI Learning Materials, Topic 5.3 – Managing File Permissions and Ownership: https://learning.lpi.org/en/learning-materials/010-160/5/5.3/
- GNU Coreutils Manual – `chmod`: https://www.gnu.org/software/coreutils/manual/html_node/chmod-invocation.html
- GNU Coreutils Manual – `chown`: https://www.gnu.org/software/coreutils/manual/html_node/chown-invocation.html
- GNU Coreutils Manual – `umask`: https://www.gnu.org/software/bash/manual/bash.html#index-umask
- Linux man-pages – `chmod(1)`: https://man7.org/linux/man-pages/man1/chmod.1.html
- Linux man-pages – `chown(1)`: https://man7.org/linux/man-pages/man1/chown.1.html