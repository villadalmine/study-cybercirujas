# 5.4 Special Directories and Files

## Übersicht

Dieses Thema behandelt zentrale Konfigurationsdateien für Benutzer und Gruppen (`/etc/passwd`, `/etc/group`, `/etc/shadow`), das Konzept von **Symbolic Links** und **Hard Links** sowie besondere Verzeichnisse wie `/tmp` und `/var/tmp`, die durch das **Sticky Bit** geschützt werden. Diese Elemente sind grundlegend, um zu verstehen, wie Linux Benutzeridentitäten verwaltet und wie das Dateisystem mit temporären, gemeinsam genutzten Daten umgeht.

## /etc/passwd

`/etc/passwd` ist die zentrale Datei, in der lokale Benutzerkonten definiert sind. Jede Zeile beschreibt einen Benutzer mit sieben durch Doppelpunkt (`:`) getrennten Feldern.

```
$ cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
maria:x:1001:1001:Maria Gonzalez:/home/maria:/bin/bash
```

Felder (von links nach rechts):

1. **Username** – Loginname des Benutzers
2. **Password placeholder** – historisch das verschlüsselte Passwort, heute meist nur `x`, da das eigentliche Passwort in `/etc/shadow` liegt
3. **UID** – User ID, numerische Kennung des Benutzers
4. **GID** – Group ID der primären Gruppe
5. **GECOS** – Kommentarfeld, üblicherweise der vollständige Name
6. **Home directory** – Pfad zum Home-Verzeichnis des Benutzers
7. **Login shell** – Shell, die beim Login gestartet wird (z. B. `/bin/bash`, oder `/usr/sbin/nologin` für Service-Accounts ohne interaktiven Login)

Da `/etc/passwd` für alle Benutzer lesbar sein muss (z. B. damit `ls -l` Usernamen anzeigen kann), enthält sie selbst keine Passwörter mehr.

## /etc/shadow

`/etc/shadow` speichert die eigentlichen, gehashten Passwörter und ist nur für `root` lesbar (`-rw-r-----` oder `-rw-------`, Owner `root`, oft Gruppe `shadow`).

```
$ sudo cat /etc/shadow
maria:$6$randomsalt$hashvalue...:19500:0:99999:7:::
```

Wichtige Felder: Username, gehashtes Passwort (Format `$id$salt$hash`, z. B. `$6$` für SHA-512), Datum der letzten Passwortänderung (Tage seit 1970-01-01), Mindest- und Maximalalter des Passworts, Warnfrist, Inaktivitätsfrist und Ablaufdatum des Accounts.

## /etc/group

`/etc/group` definiert Gruppen und deren zusätzliche (sekundäre) Mitglieder.

```
$ cat /etc/group
root:x:0:
sudo:x:27:maria
developers:x:1002:maria,juan
```

Felder: **Group name**, Passwort-Platzhalter (`x`, praktisch ungenutzt), **GID**, und eine kommagetrennte Liste der Benutzer, die dieser Gruppe als sekundäre Mitglieder angehören. Die primäre Gruppe eines Benutzers steht nicht hier, sondern als GID in `/etc/passwd`.

## Symbolic Links und Hard Links

Linux kennt zwei Arten von Links, mit denen mehrere Namen auf dieselbe Datei verweisen können.

### Hard Links

Ein **Hard Link** ist ein zusätzlicher Verzeichniseintrag, der direkt auf denselben **inode** zeigt wie das Original. Beide Namen sind gleichwertig; es gibt kein "Original" mehr.

```
$ echo "Daten" > datei.txt
$ ln datei.txt hardlink.txt
$ ls -li datei.txt hardlink.txt
123456 -rw-r--r-- 2 maria maria 6 Jul 13 10:00 datei.txt
123456 -rw-r--r-- 2 maria maria 6 Jul 13 10:00 hardlink.txt
```

Beide Dateien teilen sich dieselbe inode-Nummer (`123456`) und der **Link-Zähler** in der zweiten Spalte steht auf `2`. Wird `datei.txt` gelöscht, bleibt `hardlink.txt` mit den Daten erhalten, da die inode erst entfernt wird, wenn der Link-Zähler auf `0` fällt.

Einschränkungen: Hard Links funktionieren nur innerhalb desselben Filesystems und können nicht auf Verzeichnisse zeigen.

### Symbolic Links (Soft Links)

Ein **Symbolic Link** (auch **Symlink**) ist dagegen eine eigenständige, kleine Datei, die lediglich den Pfad zur Zieldatei enthält.

```
$ ln -s datei.txt symlink.txt
$ ls -li datei.txt symlink.txt
123456 -rw-r--r-- 1 maria maria  6 Jul 13 10:00 datei.txt
789012 lrwxrwxrwx 1 maria maria  9 Jul 13 10:02 symlink.txt -> datei.txt
```

Erkennungsmerkmale: eigene inode-Nummer (`789012`), Dateityp `l` am Zeilenanfang, sowie der Pfeil `->` mit dem Ziel. Symbolic Links können filesystemübergreifend erstellt werden und auch auf Verzeichnisse verweisen. Zeigt das Ziel auf nichts mehr (weil es gelöscht wurde), spricht man von einem **broken link** oder **dangling link**:

```
$ rm datei.txt
$ ls -l symlink.txt
lrwxrwxrwx 1 maria maria 9 Jul 13 10:02 symlink.txt -> datei.txt
$ cat symlink.txt
cat: symlink.txt: No such file or directory
```

## /tmp, /var/tmp und das Sticky Bit

`/tmp` und `/var/tmp` sind Verzeichnisse für temporäre Dateien, auf die **alle Benutzer** schreiben dürfen. Der Unterschied liegt in der Lebensdauer: Inhalte von `/tmp` können beim Neustart gelöscht werden (je nach Distribution, oft via `systemd-tmpfiles`), während `/var/tmp` für Daten gedacht ist, die einen Reboot überdauern sollen.

Da beide Verzeichnisse world-writable sind, könnte ohne Schutz jeder Benutzer die Dateien eines anderen Benutzers löschen. Dagegen schützt das **Sticky Bit**: Ist es gesetzt, darf eine Datei in diesem Verzeichnis nur vom Owner der Datei, dem Owner des Verzeichnisses oder `root` gelöscht bzw. umbenannt werden – unabhängig von den regulären write permissions.

```
$ ls -ld /tmp
drwxrwxrwt 15 root root 4096 Jul 13 10:05 /tmp
```

Das `t` an letzter Stelle der permissions (statt `x`) zeigt das gesetzte Sticky Bit. Gesetzt wird es mit dem symbolischen Modus:

```
$ chmod +t /verzeichnis
$ chmod 1777 /verzeichnis   # entspricht drwxrwxrwt
```

Die führende `1` in der numerischen Notation (`1777`) repräsentiert das Sticky Bit, analog zur `4` für SUID und `2` für SGID.

## Referencias

- LPI Learning Materials – 010-160, Topic 5.4: https://learning.lpi.org/en/learning-materials/010-160/5/5.4/
- `man 5 passwd`
- `man 5 shadow`
- `man 5 group`
- `man 1 ln`
- `man 1 chmod`