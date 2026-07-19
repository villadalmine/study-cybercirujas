# 2.3 Using Directories and Listing Files

**Gewichtung im Examen: 2**

## Überblick

Linux organisiert alle Daten in einem hierarchischen Dateisystem, das wie ein umgedrehter Baum aufgebaut ist: An der Spitze steht das **root directory** `/`, darunter verzweigen sich alle weiteren Verzeichnisse. In diesem Thema lernst du, dich mit der Shell in dieser Struktur zu bewegen (`cd`), deinen Standort zu bestimmen (`pwd`) und Dateien aufzulisten (`ls`) — die drei grundlegendsten Werkzeuge der täglichen Arbeit auf der Kommandozeile.

---

## Das Dateisystem als Baum

Jede Datei und jedes Verzeichnis ist vom root directory `/` aus erreichbar. Typische Verzeichnisse direkt unterhalb von `/`:

```
/
├── bin/     → grundlegende Programme (binaries)
├── etc/     → Konfigurationsdateien
├── home/    → home directories der Benutzer
│   ├── carol/
│   └── david/
├── tmp/     → temporäre Dateien
├── usr/     → Programme und Bibliotheken
└── var/     → veränderliche Daten (Logs, Spool)
```

Wichtig: Unter Linux trennt der **forward slash** `/` die Ebenen eines Pfads (nicht der backslash `\` wie unter Windows). Außerdem ist das Dateisystem **case-sensitive**: `Dokument.txt`, `dokument.txt` und `DOKUMENT.TXT` sind drei verschiedene Dateien.

## Das Home Directory

Jeder Benutzer besitzt ein eigenes **home directory**, üblicherweise unter `/home/<benutzername>` (z. B. `/home/carol`). Dort landen persönliche Dateien und Konfigurationen. Nach dem Login startet die Shell in diesem Verzeichnis.

Die Shell bietet dafür eine Abkürzung: Die **tilde** `~` steht immer für das home directory des aktuellen Benutzers.

```bash
$ echo ~
/home/carol
```

---

## `pwd` — Wo bin ich?

Der Befehl `pwd` (**print working directory**) zeigt das aktuelle Arbeitsverzeichnis als absoluten Pfad an:

```bash
$ pwd
/home/carol/Dokumente
```

Das **current working directory** ist der Bezugspunkt für alle relativen Pfade (siehe unten). Viele Shells zeigen es zusätzlich im Prompt an.

## Absolute und relative Pfade

Es gibt zwei Arten, den Ort einer Datei anzugeben:

| Pfadtyp | Merkmal | Beispiel |
|---|---|---|
| **absolute path** | beginnt immer mit `/`, gilt von überall | `/home/carol/Dokumente/brief.txt` |
| **relative path** | beginnt *nicht* mit `/`, gilt ab dem current working directory | `Dokumente/brief.txt` |

Zwei spezielle Einträge existieren in **jedem** Verzeichnis:

- `.` — das aktuelle Verzeichnis selbst
- `..` — das **parent directory** (eine Ebene höher)

Beispiel: Du befindest dich in `/home/carol/Dokumente`. Dann verweisen:

```bash
$ pwd
/home/carol/Dokumente
$ cd ..        # wechselt nach /home/carol
$ cd ../..     # von /home/carol nach / (zwei Ebenen hoch)
```

Relative Pfade lassen sich auch kombinieren: `../david/Musik` bedeutet „eine Ebene hoch, dann in `david/Musik` hinein".

## `cd` — Verzeichnis wechseln

Mit `cd` (**change directory**) bewegst du dich durch den Verzeichnisbaum:

```bash
$ cd /etc              # absoluter Pfad
$ cd Dokumente         # relativer Pfad (ab dem aktuellen Verzeichnis)
$ cd ..                # ins parent directory
$ cd ~                 # ins eigene home directory
$ cd                   # ohne Argument: ebenfalls ins home directory
$ cd -                 # zurück zum vorherigen Verzeichnis
```

Der Sonderfall `cd -` ist im Alltag sehr praktisch: Er springt zum zuletzt besuchten Verzeichnis zurück und gibt dessen Pfad aus:

```bash
$ pwd
/home/carol
$ cd /var/log
$ cd -
/home/carol
```

---

## `ls` — Dateien auflisten

`ls` (**list**) zeigt den Inhalt eines Verzeichnisses. Ohne Argument listet es das current working directory, mit Argument jedes beliebige Verzeichnis:

```bash
$ ls
Bilder  Dokumente  Downloads  Musik  notizen.txt
$ ls /etc
adduser.conf  bash.bashrc  fstab  hostname  hosts  ...
```

### Das lange Format: `ls -l`

Die Option `-l` (**long listing**) zeigt Details zu jeder Datei:

```bash
$ ls -l
drwxr-xr-x 2 carol carol 4096 Jul 10 09:30 Dokumente
-rw-r--r-- 1 carol carol 1250 Jul 12 14:02 notizen.txt
```

Die Spalten von links nach rechts:

1. **Dateityp und permissions** — das erste Zeichen zeigt den Typ: `-` für eine reguläre Datei, `d` für ein directory, `l` für einen symbolic link. Danach folgen die Zugriffsrechte.
2. **Anzahl der links** auf die Datei
3. **Owner** (Besitzer)
4. **Group** (Gruppe)
5. **Größe** in Bytes
6. **Zeitstempel** der letzten Änderung
7. **Name**

### Hidden Files: `ls -a`

Dateien, deren Name mit einem Punkt beginnt (**dotfiles**, z. B. `.bashrc`), sind versteckt und werden von `ls` standardmäßig nicht angezeigt. Die Option `-a` (**all**) macht sie sichtbar — inklusive der Einträge `.` und `..`:

```bash
$ ls -a
.  ..  .bashrc  .profile  Bilder  Dokumente  notizen.txt
```

Hidden files sind kein Sicherheitsmechanismus, sondern eine Konvention, um Konfigurationsdateien aus dem Weg zu halten.

### Lesbare Größen: `ls -h`

Die Option `-h` (**human-readable**) zeigt Größen in K, M oder G statt in Bytes — sinnvoll nur in Kombination mit `-l`:

```bash
$ ls -lh
drwxr-xr-x 2 carol carol 4,0K Jul 10 09:30 Dokumente
-rw-r--r-- 1 carol carol 1,3K Jul 12 14:02 notizen.txt
-rw-r--r-- 1 carol carol 2,1G Jul 15 18:44 backup.tar
```

### Weitere nützliche Optionen

| Option | Wirkung |
|---|---|
| `-R` | **recursive** — listet auch alle Unterverzeichnisse |
| `-t` | sortiert nach Änderungszeit (neueste zuerst) |
| `-S` | sortiert nach Größe (größte zuerst) |
| `-r` | **reverse** — kehrt die Sortierreihenfolge um |
| `-d` | zeigt das Verzeichnis selbst statt seines Inhalts |

Optionen lassen sich kombinieren. Ein Klassiker ist `ls -lah` (long listing, alle Dateien, lesbare Größen) oder `ls -ltr` (nach Zeit sortiert, älteste zuletzt — die neuesten Dateien stehen dann direkt über dem Prompt):

```bash
$ ls -ltr /var/log
-rw-r--r-- 1 root root  32K Jul 17 06:25 dpkg.log
-rw-r--r-- 1 root root 130K Jul 19 08:12 syslog
```

---

## Zusammenspiel: ein typischer Arbeitsablauf

```bash
$ pwd                      # Standort prüfen
/home/carol
$ ls                       # Inhalt ansehen
Bilder  Dokumente  Downloads  notizen.txt
$ cd Dokumente/Projekte    # relativ hineinwechseln
$ pwd
/home/carol/Dokumente/Projekte
$ ls -lah                  # Details inkl. hidden files
$ cd ../..                 # zwei Ebenen zurück ins home directory
$ cd -                     # und wieder zurück nach Projekte
/home/carol/Dokumente/Projekte
```

## Zusammenfassung der Kernpunkte

- Das Dateisystem beginnt beim **root directory** `/`; Pfade trennen Ebenen mit `/` und sind **case-sensitive**.
- **Absolute Pfade** beginnen mit `/`; **relative Pfade** beziehen sich auf das current working directory.
- `.` = aktuelles Verzeichnis, `..` = parent directory, `~` = home directory.
- `pwd` zeigt den Standort, `cd` wechselt das Verzeichnis (`cd` allein → home, `cd -` → vorheriges Verzeichnis).
- `ls` listet Dateien; wichtigste Optionen: `-l` (Details), `-a` (hidden files), `-h` (lesbare Größen), `-R` (rekursiv), `-t`/`-S`/`-r` (Sortierung).

## Referenzen

- LPI Learning Materials, Thema 2.3 — Using Directories and Listing Files: https://learning.lpi.org/en/learning-materials/010-160/2/2.3/
- GNU Coreutils Manual — `ls`: https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html
- GNU Coreutils Manual — `pwd`: https://www.gnu.org/software/coreutils/manual/html_node/pwd-invocation.html
- GNU Bash Manual — Builtin Commands (`cd`): https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
- Filesystem Hierarchy Standard (FHS): https://refspecs.linuxfoundation.org/fhs.shtml