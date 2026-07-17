# LPI Linux Essentials (010-160) – Thema 4.3: Where Data is Stored

## Übung 1: Systemkonfiguration in /etc erkunden

1. Wechsle in das Verzeichnis `/etc` und verschaffe dir einen Überblick:
   ```
   cd /etc
   ls -l | head -20
   ```
2. Zeige den Inhalt von `/etc/passwd` an:
   ```
   cat /etc/passwd
   ```
3. Suche darin nach deinem eigenen Benutzereintrag:
   ```
   grep "^$(whoami):" /etc/passwd
   ```
4. Vergleiche `/etc/hostname` mit der Ausgabe von `hostname`:
   ```
   cat /etc/hostname
   hostname
   ```
5. Öffne `/etc/hosts` und notiere die Einträge für `localhost`:
   ```
   cat /etc/hosts
   ```

**Verständnisfragen**
- Aus wie vielen Feldern besteht ein Eintrag in `/etc/passwd` (durch `:` getrennt), und wofür steht das dritte Feld?
- Warum enthält `/etc/passwd` heute keine echten Passwort-Hashes mehr, obwohl der Dateiname das nahelegt?
- Welche Rolle spielt `/etc/hosts` im Vergleich zu DNS?

## Übung 2: Prozess- und Kernel-Informationen unter /proc

1. Zeige Prozessor-Informationen an:
   ```
   cat /proc/cpuinfo
   ```
2. Zeige Arbeitsspeicher-Informationen an:
   ```
   cat /proc/meminfo
   ```
3. Ermittle die PID der aktuellen Shell:
   ```
   echo $$
   ```
4. Untersuche das /proc-Verzeichnis dieses Prozesses:
   ```
   ls -l /proc/$$
   cat /proc/$$/status | head -5
   cat /proc/$$/cmdline
   ```
5. Vergleiche die Ausgabe mit `free -h`:
   ```
   free -h
   ```

**Verständnisfragen**
- Ist `/proc` ein "echtes" Dateisystem auf einem Speichermedium? Begründe.
- Welche Information liefert `/proc/<PID>/cmdline`, die in der Kurzübersicht von `ps` oft nicht vollständig sichtbar ist?
- Was passiert mit dem Verzeichnis `/proc/<PID>`, sobald der zugehörige Prozess endet?

## Übung 3: Logdateien unter /var/log auswerten

1. Liste den Inhalt von `/var/log` auf:
   ```
   ls -l /var/log
   ```
2. Zeige die letzten Zeilen des System-Logs an:
   ```
   sudo tail -n 20 /var/log/syslog
   ```
   oder auf Systemen mit systemd-journal:
   ```
   journalctl -n 20
   ```
3. Filtere Journal-Einträge der letzten 10 Minuten:
   ```
   journalctl --since "10 minutes ago"
   ```
4. Suche nach Fehlermeldungen im aktuellen Boot:
   ```
   journalctl -p err -b
   ```
5. Prüfe die Größe der Logdateien:
   ```
   du -sh /var/log/*
   ```

**Verständnisfragen**
- Warum ist für das Lesen vieler Dateien in `/var/log` oft `sudo` nötig?
- Welchen Vorteil bietet `journalctl` gegenüber dem direkten Durchsuchen von Textdateien wie `/var/log/syslog`?
- Was filtert die Option `-p err` bei `journalctl`?

## Übung 4: Eingehängte Dateisysteme und /etc/fstab

1. Zeige alle aktuell gemounteten Dateisysteme an:
   ```
   mount | column -t
   ```
2. Zeige die Speicherplatznutzung übersichtlich an:
   ```
   df -h
   ```
3. Untersuche den Aufbau von `/etc/fstab`:
   ```
   cat /etc/fstab
   ```
4. Identifiziere, welches Gerät oder welche UUID auf `/` gemountet wird.
5. Liste die Blockgeräte des Systems auf:
   ```
   lsblk
   ```

**Verständnisfragen**
- Aus welchen Feldern besteht eine Zeile in `/etc/fstab` (nenne mindestens vier)?
- Was ist der Unterschied zwischen einer Angabe per Gerätename (z. B. `/dev/sda1`) und per UUID in `/etc/fstab`?
- Zu welchem Zeitpunkt wertet das System `/etc/fstab` aus?

## Übung 5: Zusammenfassende Aufgabe

1. Ermittle mit einem einzigen Befehl, wie viel Prozent des Root-Dateisystems (`/`) belegt sind.
2. Ermittle den gesamten physischen Arbeitsspeicher sowohl über `free` als auch über `/proc/meminfo`.
3. Finde heraus, welche Boot-Vorgänge im Journal erfasst sind und zeige die letzten Einträge des vorherigen Boots:
   ```
   journalctl --list-boots
   journalctl -b -1 -n 5
   ```

**Verständnisfragen**
- Welche drei Stellen aus den vorherigen Übungen würdest du zuerst prüfen, wenn ein System wegen Platzmangels Probleme meldet?
- Warum belegt `/proc` keinen Speicherplatz auf der Festplatte, obwohl `ls -l` dort Dateigrößen anzeigt?

## Quellen
- LPI Learning Materials, Thema 4.3 "Where Data is Stored": https://learning.lpi.org/en/learning-materials/010-160/4/4.3/

<details>
<summary>Antworten</summary>

**Übung 1**
- 7 Felder: Benutzername, Passwort-Platzhalter, UID, GID, GECOS/Kommentar, Home-Verzeichnis, Login-Shell. Das dritte Feld ist die UID (User ID).
- Die Hashes wurden aus Sicherheitsgründen nach `/etc/shadow` ausgelagert, das nur für root lesbar ist. `/etc/passwd` muss dagegen für alle Prozesse lesbar bleiben (z. B. zur Auflösung von Benutzernamen), daher steht dort nur ein Platzhalter wie `x`.
- `/etc/hosts` liefert eine statische, lokale Zuordnung von Hostnamen zu IP-Adressen, die (abhängig von `/etc/nsswitch.conf`) meist vor einer DNS-Abfrage ausgewertet wird. DNS ist dagegen dynamisch und netzwerkweit gültig.

**Übung 2**
- Nein, `/proc` ist ein virtuelles Pseudo-Dateisystem (procfs), das der Kernel zur Laufzeit im Arbeitsspeicher erzeugt und das den aktuellen Kernel- und Prozesszustand widerspiegelt.
- `cmdline` zeigt die vollständige Befehlszeile inklusive aller Argumente, mit der der Prozess gestartet wurde.
- Der Kernel entfernt das Verzeichnis `/proc/<PID>` automatisch, sobald der Prozess terminiert.

**Übung 3**
- Viele Logs enthalten sicherheitsrelevante Informationen und sind daher nur für root bzw. Mitglieder bestimmter Gruppen (z. B. `adm`) lesbar.
- `journalctl` erlaubt strukturiertes Filtern nach Zeit, Priorität, Unit oder Boot-Vorgang, ohne dass Textdateien und deren Rotation manuell berücksichtigt werden müssen.
- `-p err` filtert auf Meldungen mit Priorität "error" oder höher (error, crit, alert, emerg).

**Übung 4**
- Gerät/UUID (fs_spec), Mountpoint (fs_file), Dateisystemtyp (fs_vfstype), Mount-Optionen (fs_mntops), Dump-Flag (fs_freq), fsck-Reihenfolge (fs_passno).
- Ein Gerätename wie `/dev/sda1` kann sich bei Hardware- oder Bootreihenfolgeänderungen verschieben; eine UUID bleibt dem Dateisystem fest zugeordnet, unabhängig vom Gerätenamen.
- Beim Systemstart, damit das Init-System die gelisteten Dateisysteme automatisch mountet; zusätzlich bei manuellem `mount -a`.

**Übung 5**
- `df -h` für Dateisystembelegung, `/var/log` für eventuell übergroße Logdateien, sowie `free`/`/proc/meminfo` zur Unterscheidung von Festplatten- und Arbeitsspeicherknappheit.
- `/proc` wird vollständig im Kernel-Speicher zur Laufzeit generiert; die von `ls -l` angezeigten "Dateigrößen" sind virtuell und entsprechen keinen tatsächlich belegten Blöcken auf einem Speichermedium.

</details>