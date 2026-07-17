# 2.2 Die Kommandozeile nutzen, um Hilfe zu bekommen

## Überblick

Linux-Systeme bringen für praktisch jedes installierte Programm eine eingebaute Dokumentation mit. Bevor man online sucht, lohnt es sich, direkt auf der Kommandozeile nachzuschauen — das funktioniert auch offline, ist versionsgenau (die Doku passt zur installierten Software) und ist eine Kernkompetenz, die in der Linux Essentials-Prüfung abgefragt wird. Die wichtigsten Werkzeuge dafür sind `man`, `info`, die `--help`-Option sowie die Dateien unter `/usr/share/doc/`.

## man Pages

Das `man`-System (Manual) ist die klassische Referenzdokumentation für Kommandos, Systemaufrufe, Konfigurationsdateien und mehr.

```bash
$ man ls
```

Das öffnet die Manual Page zu `ls` im Pager (meist `less`). Navigation innerhalb der man page:

| Taste | Aktion |
|---|---|
| `Leertaste` / `f` | eine Seite vorwärts |
| `b` | eine Seite zurück |
| `/muster` | vorwärts suchen nach "muster" |
| `n` | nächstes Suchergebnis |
| `q` | man page verlassen |

### Aufbau einer man page

Man pages folgen einer standardisierten Struktur, unabhängig vom Kommando:

- **NAME** — Name und Kurzbeschreibung
- **SYNOPSIS** — Aufrufsyntax mit Optionen
- **DESCRIPTION** — ausführliche Beschreibung
- **OPTIONS** — Erklärung aller Flags/Optionen
- **EXAMPLES** — Beispielaufrufe (nicht immer vorhanden)
- **FILES** — relevante Konfigurationsdateien
- **SEE ALSO** — verwandte man pages
- **AUTHOR** / **BUGS** — Autor, bekannte Probleme

### man Sections (Kapitel)

Das Manual ist in nummerierte Sections unterteilt, weil derselbe Name mehrfach vorkommen kann — z. B. gibt es sowohl das Kommando `passwd` als auch die Konfigurationsdatei `passwd`:

| Section | Inhalt |
|---|---|
| 1 | Ausführbare Programme / Shell-Kommandos |
| 2 | System calls (Kernel-Funktionen) |
| 3 | Library calls (C-Bibliotheksfunktionen) |
| 4 | Spezialdateien (z. B. in `/dev`) |
| 5 | Dateiformate und Konventionen (z. B. `/etc/passwd`) |
| 6 | Spiele |
| 7 | Diverses (Makro-Pakete, Konventionen) |
| 8 | Systemverwaltungskommandos (meist root) |

Um eine bestimmte Section zu erzwingen, gibt man die Nummer vor dem Namen an:

```bash
$ man 5 passwd     # Dateiformat von /etc/passwd
$ man 1 passwd      # das passwd-Kommando
```

Mit `man -f` bzw. dem gleichbedeutenden Kommando `whatis` sieht man, in welchen Sections ein Name vorkommt:

```bash
$ whatis passwd
passwd (1)           - change user password
passwd (5)           - password file
```

### Volltextsuche: apropos / man -k

Wenn man den genauen Kommandonamen nicht kennt, hilft eine Stichwortsuche über alle NAME-Zeilen der man-Datenbank:

```bash
$ apropos "list directory"
ls (1)                - list directory contents
```

`man -k` ist gleichbedeutend mit `apropos`:

```bash
$ man -k partition
fdisk (8)             - manipulate disk partition table
parted (8)            - a partition manipulation program
```

Damit `apropos`/`whatis` funktionieren, muss der Suchindex existieren; er wird über `mandb` (bzw. `makewhatis` auf manchen Distributionen) aufgebaut, meist automatisch bei der Paketinstallation.

## info Pages

`info` ist ein alternatives, hypertextartiges Dokumentationssystem des GNU-Projekts, oft ausführlicher als die zugehörige man page, besonders bei GNU-Tools wie `grep`, `tar` oder `gcc`.

```bash
$ info coreutils
```

Info-Dokumente sind in Nodes gegliedert, zwischen denen man springen kann:

| Taste | Aktion |
|---|---|
| `Leertaste` | vorwärts blättern |
| `n` | nächster Node |
| `p` | vorheriger Node |
| `u` | eine Ebene nach oben (up) |
| `Enter` auf Link | Link folgen |
| `l` | zurück zum letzten besuchten Node |
| `q` | info verlassen |

## Die --help Option

Fast jedes Kommando unterstützt `--help` (oder bei manchen älteren Tools nur `-h`), um eine knappe Übersicht der Optionen direkt im Terminal auszugeben — ohne Pager, ideal für einen schnellen Blick:

```bash
$ ls --help
Usage: ls [OPTION]... [FILE]...
List information about the FILEs (the current directory by default).
...
  -a, --all                  do not ignore entries starting with .
  -l                         use a long listing format
...
```

`--help` ist knapper als `man`, eignet sich aber gut, um schnell die Syntax einer Option nachzuschlagen, ohne die man page zu verlassen.

## Dokumentation unter /usr/share/doc

Installierte Pakete legen oft zusätzliche Dokumentation als Dateien ab, z. B. README, CHANGELOG, Beispielkonfigurationen oder Lizenztexte:

```bash
$ ls /usr/share/doc/bash/
AUTHORS  bashbug.gz  changelog.Debian.gz  COPYING  README
```

Diese Dateien sind reine Text- oder oft gzip-komprimierte Dateien (`.gz`), die man mit `less` bzw. `zless`/`zcat` lesen kann:

```bash
$ zless /usr/share/doc/bash/changelog.Debian.gz
```

Diese Quelle lohnt sich besonders für Release Notes, bekannte Probleme (Known Issues) und ausführlichere Beispiele, die in der man page fehlen.

## Zusammenfassung der Werkzeuge

| Werkzeug | Zweck | Typischer Aufruf |
|---|---|---|
| `man <cmd>` | vollständige Referenzdoku | `man ls` |
| `man <section> <cmd>` | Doku aus bestimmter Section | `man 5 passwd` |
| `whatis <cmd>` | Kurzbeschreibung + Sections | `whatis passwd` |
| `apropos <stichwort>` / `man -k` | Volltextsuche über NAME-Zeilen | `apropos partition` |
| `info <cmd>` | ausführliche GNU-Hypertext-Doku | `info coreutils` |
| `<cmd> --help` | knappe Optionsübersicht im Terminal | `ls --help` |
| `/usr/share/doc/<paket>/` | zusätzliche Dateien (README, Changelog) | `ls /usr/share/doc/bash/` |

## Referenzen

- LPI Learning Materials — Topic 2.2: Using the Command Line to Get Help: https://learning.lpi.org/en/learning-materials/010-160/2/2.2/
- man-pages Projekt (Linux man-pages): https://www.kernel.org/doc/man-pages/
- GNU Info Reader Dokumentation: https://www.gnu.org/software/texinfo/manual/info/
- GNU Coreutils Manual: https://www.gnu.org/software/coreutils/manual/