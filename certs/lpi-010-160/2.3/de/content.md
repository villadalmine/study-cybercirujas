# 2.3 Using Directories and Listing Files

## Überblick

Um sich sicher innerhalb der Filesystem-Hierarchy zu bewegen, sind drei Commands zentral: `pwd`, `cd` und `ls`. Dieses Thema behandelt die Directory-Struktur, absolute und relative Paths sowie das Lesen der `ls -l` Long-Listing-Ausgabe.

## Die Filesystem-Hierarchie

Jedes Linux-System besitzt genau ein Root Directory, dargestellt durch `/`. Von dort aus verzweigen sich alle weiteren Directories baumartig, z. B. `/home`, `/etc`, `/var` oder `/usr`. Jeder User besitzt üblicherweise ein eigenes Home Directory unter `/home/<username>` (bei root: `/root`), referenzierbar über die Tilde `~`.

In jedem Directory existieren zwei spezielle Einträge:
- `.` referenziert das aktuelle Directory
- `..` referenziert das Parent Directory

## Absolute und relative Paths

Ein **absoluter Path** beginnt immer mit `/` und beschreibt den vollständigen Weg vom Root Directory aus, unabhängig vom aktuellen Standort:

```
/home/anna/Documents/report.txt
```

Ein **relativer Path** wird ausgehend vom aktuellen Working Directory interpretiert und beginnt nicht mit `/`:

```
Documents/report.txt
../Pictures/photo.png
./script.sh
```

## Position bestimmen: `pwd`

`pwd` (print working directory) zeigt den absoluten Path des aktuellen Working Directory:

```
$ pwd
/home/anna
```

## Navigation: `cd`

Mit `cd` (change directory) wechselt man das Working Directory:

```
$ cd /etc              # absoluter Path
$ cd Documents          # relativer Path, Subdirectory
$ cd ..                 # eine Ebene nach oben
$ cd ~                  # zurück zum eigenen Home Directory
$ cd                    # ohne Argument: ebenfalls Home Directory
$ cd -                  # zurück zum vorherigen Working Directory
```

Beispiel-Session:

```
$ pwd
/home/anna
$ cd /var/log
$ pwd
/var/log
$ cd -
/home/anna
$ pwd
/home/anna
```

## Directory-Inhalt auflisten: `ls`

`ls` (list) zeigt den Inhalt eines Directory. Ohne Argument wird das Working Directory verwendet:

```
$ ls
Desktop  Documents  Downloads  Music  Pictures
```

Ein anderes Directory kann direkt als Argument übergeben werden:

```
$ ls /etc
adduser.conf  apt  bash.bashrc  cron.d  hostname  hosts  ...
```

### Wichtige Optionen von `ls`

| Option | Bedeutung |
|---|---|
| `-l` | Long Listing Format mit Details (Permissions, Owner, Size, Date) |
| `-a` | zeigt auch hidden files (Name beginnt mit `.`), inklusive `.` und `..` |
| `-A` | wie `-a`, aber ohne `.` und `..` |
| `-h` | Dateigrößen human-readable (z. B. `4.0K`, `1.2M`) |
| `-d` | zeigt Directories selbst an, nicht ihren Inhalt |
| `-F` | hängt Symbole an Einträge an (`/` Directory, `*` executable, `@` Symlink) |
| `-R` | listet rekursiv, inklusive aller Subdirectories |
| `-t` | sortiert nach Modification Time (neueste zuerst) |
| `-S` | sortiert nach Dateigröße (größte zuerst) |
| `-r` | kehrt die Sortierreihenfolge um |

Optionen lassen sich kombinieren, z. B. `ls -lah`.

### Hidden Files (Dotfiles)

Dateien und Directories, deren Name mit einem Punkt beginnt (z. B. `.bashrc`, `.config`), gelten als **hidden** und werden von `ls` standardmäßig nicht angezeigt:

```
$ ls
Desktop  Documents  Downloads

$ ls -a
.  ..  .bash_history  .bashrc  .config  Desktop  Documents  Downloads
```

### Die `ls -l`-Ausgabe verstehen

```
$ ls -l /etc/hosts /home/anna
-rw-r--r-- 1 root root  174 Mär  3 09:12 /etc/hosts

/home/anna:
total 24
drwxr-xr-x  2 anna anna 4096 Jun 20 14:05 Desktop
-rw-r--r--  1 anna anna  220 Jun 20 14:05 .bash_logout
drwxr-xr-x  3 anna anna 4096 Jun 21 08:41 Documents
```

Jede Zeile besteht, von links nach rechts, aus folgenden Feldern:

1. **File Type + Permissions** (10 Zeichen), z. B. `drwxr-xr-x`
   - erstes Zeichen: File Type — `-` reguläre Datei, `d` Directory, `l` Symlink
   - restliche 9 Zeichen: Permissions für Owner, Group und Others (`rwx`)
2. **Link Count** — Anzahl der Hard Links (bei Directories inklusive `.`-Eintrag und `..`-Verweisen der Subdirectories)
3. **Owner** — der User, dem die Datei gehört
4. **Group** — die Group, der die Datei zugeordnet ist
5. **Size** — Dateigröße in Bytes (mit `-h` human-readable)
6. **Modification Timestamp** — Datum/Uhrzeit der letzten Änderung
7. **Name** — Datei- bzw. Directory-Name

Das `total`-Feld oberhalb der Liste gibt die Summe der belegten Blocks an, nicht die Anzahl der Dateien.

### Weitere praktische Beispiele

Nach Größe sortiert, human-readable:

```
$ ls -lhS /var/log
total 3.2M
-rw-r-----  1 syslog adm  1.8M Jul 12 10:03 syslog
-rw-r-----  1 syslog adm  640K Jul  5 00:00 syslog.1
-rw-r--r--  1 root   root  12K Jul 12 09:58 dpkg.log
```

Nur Directories selbst anzeigen, nicht deren Inhalt (`-d`):

```
$ ls -ld /home /etc /var
drwxr-xr-x   4 root root  4096 Jun 10 12:00 /home
drwxr-xr-x 142 root root 12288 Jul 12 08:00 /etc
drwxr-xr-x  13 root root  4096 May 22 07:15 /var
```

Rekursives Listing eines kleinen Projekt-Directory:

```
$ ls -R project/
project/:
README.md  src

project/src:
main.py  utils.py
```

## Zusammenfassung

- `pwd` zeigt den aktuellen Standort im Filesystem.
- `cd` navigiert zwischen Directories, über absolute oder relative Paths.
- `ls` listet Directory-Inhalte; Optionen wie `-l`, `-a`, `-h`, `-d`, `-R`, `-t`, `-S` steuern Format und Umfang der Ausgabe.
- Die `ls -l`-Ausgabe liefert Type, Permissions, Owner, Group, Size und Modification Time in fester Spaltenreihenfolge.
- Dotfiles sind standardmäßig versteckt und werden erst mit `-a`/`-A` sichtbar.

## Referenzen

- LPI Learning Materials, Topic 2.3 "Using Directories and Listing Files": https://learning.lpi.org/en/learning-materials/010-160/2/2.3/
- GNU Coreutils Manual, `ls`: https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html
- GNU Bash Reference Manual, Bourne Shell Builtins (`cd`): https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html

---

Ich habe in dieser Session keinen Zugriff auf Datei-Tools (Read/Write/Bash), daher konnte ich den Text nicht direkt in `certs/lpi-010-160/2.3/de/` speichern — hier ist der vollständige Inhalt zum manuellen Einfügen.