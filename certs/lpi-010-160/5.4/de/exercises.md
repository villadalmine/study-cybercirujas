# Übungen: 5.4 Special Directories and Files

*Quelle (nur als Referenz, kein Zitat wörtlich übernommen): https://learning.lpi.org/en/learning-materials/010-160/5/5.4/*

## Übung 1: Die Datei `/etc/passwd` untersuchen

**Schritte:**

1. Öffne ein Terminal.
2. Gib den Befehl `cat /etc/passwd` ein und sieh dir die Ausgabe an.
3. Suche mit `grep "^$(whoami):" /etc/passwd` nach deinem eigenen User-Eintrag.
4. Zähle, aus wie vielen Feldern (getrennt durch `:`) eine einzelne Zeile besteht.
5. Identifiziere in deinem Eintrag die Felder für **username**, **UID**, **GID**, **home directory** und **login shell**.

**Verständnisfragen:**

1. Warum enthält `/etc/passwd` heute meist keine echten Passwort-Hashes mehr, obwohl der Name das suggeriert?
2. Was bedeutet es, wenn das Feld für die login shell auf `/usr/sbin/nologin` oder `/bin/false` gesetzt ist?

---

## Übung 2: Logdateien in `/var/log`

**Schritte:**

1. Liste den Inhalt von `/var/log` mit `ls -l /var/log`.
2. Öffne (als root, z. B. via `sudo`) die aktuelle System-Logdatei deiner Distribution, z. B. mit `sudo tail -n 20 /var/log/syslog` oder `sudo journalctl -n 20`, je nachdem ob dein System klassische Logdateien oder `systemd-journald` verwendet.
3. Beobachte neue Einträge in Echtzeit mit `sudo tail -f /var/log/syslog` (mit `Strg+C` beenden).
4. Öffne in einem zweiten Terminal eine neue SSH-Sitzung oder führe `sudo -k` gefolgt von einem `sudo`-Befehl aus, um einen neuen Log-Eintrag zu erzeugen, und beobachte ihn im ersten Terminal.

**Verständnisfragen:**

1. Warum liegt `/var/log` unter `/var` und nicht unter `/etc` oder `/usr`?
2. Welchen Vorteil bietet `tail -f` gegenüber wiederholtem `cat` derselben Datei?

---

## Übung 3: Das virtuelle Dateisystem `/proc`

**Schritte:**

1. Zeige Informationen über den Prozessor mit `cat /proc/cpuinfo`.
2. Zeige Informationen über den Arbeitsspeicher mit `cat /proc/meminfo`.
3. Finde die PID deiner aktuellen Shell mit `echo $$`.
4. Liste das Verzeichnis dieser PID mit `ls -l /proc/<PID>` (ersetze `<PID>` durch den Wert aus Schritt 3).
5. Zeige das aktuelle Arbeitsverzeichnis dieses Prozesses mit `ls -l /proc/<PID>/cwd`.
6. Prüfe die Größe von `/proc/cpuinfo` mit `ls -l /proc/cpuinfo` und vergleiche sie mit der Ausgabe von `wc -c /proc/cpuinfo`.

**Verständnisfragen:**

1. Warum zeigt `ls -l /proc/cpuinfo` in der Regel eine Dateigröße von `0` Bytes, obwohl `cat` sichtbaren Inhalt liefert?
2. Was passiert mit dem Verzeichnis `/proc/<PID>`, sobald der zugehörige Prozess beendet wird?

---

## Übung 4: Gerätedateien in `/dev`

**Schritte:**

1. Liste den Inhalt von `/dev` mit `ls -l /dev`.
2. Suche gezielt nach deiner Festplatte bzw. SSD, z. B. mit `ls -l /dev/sd* /dev/nvme* 2>/dev/null`.
3. Betrachte das erste Zeichen der Berechtigungsspalte (`ls -l`) bei einem Eintrag wie `/dev/sda` und bei `/dev/tty1`.
4. Führe `file /dev/null` und `file /dev/sda` (bzw. das gefundene Gerät) aus und vergleiche die Ausgabe.
5. Teste `echo "test" > /dev/null` und anschließend `cat /dev/null`.

**Verständnisfragen:**

1. Was unterscheidet ein **character device** von einem **block device**, und woran erkennst du den Typ in der `ls -l`-Ausgabe?
2. Warum liefert `cat /dev/null` niemals Ausgabe, egal wie oft zuvor in die Datei geschrieben wurde?

---

## Übung 5: Hard Links vs. Symbolic Links

**Schritte:**

1. Wechsle in ein Testverzeichnis: `mkdir ~/linktest && cd ~/linktest`.
2. Erstelle eine Datei: `echo "Originaltext" > original.txt`.
3. Erstelle einen **hard link**: `ln original.txt hardlink.txt`.
4. Erstelle einen **symbolic (soft) link**: `ln -s original.txt softlink.txt`.
5. Vergleiche die Inode-Nummern mit `ls -li`.
6. Zeige die Anzahl der Hard Links pro Datei in der zweiten Spalte von `ls -l` an.
7. Ändere den Inhalt über den Link: `echo "Neuer Text" >> hardlink.txt`, und prüfe `cat original.txt`.
8. Lösche die Originaldatei: `rm original.txt`.
9. Prüfe, ob `cat hardlink.txt` noch funktioniert.
10. Prüfe, ob `cat softlink.txt` noch funktioniert, und interpretiere die Fehlermeldung.

**Verständnisfragen:**

1. Warum zeigen `original.txt` und `hardlink.txt` in Schritt 5 dieselbe Inode-Nummer, `softlink.txt` aber eine andere?
2. Warum funktioniert `hardlink.txt` nach dem Löschen von `original.txt` weiterhin, `softlink.txt` jedoch nicht mehr?
3. Nenne eine Einschränkung von Hard Links, die für Symbolic Links nicht gilt (z. B. bezüglich Verzeichnissen oder Dateisystemgrenzen).

---

<details>
<summary><strong>Lösungen</strong></summary>

**Übung 1**

1. Passwort-Hashes liegen aus Sicherheitsgründen in `/etc/shadow`, das nur für root lesbar ist. `/etc/passwd` muss dagegen für alle Prozesse lesbar sein (z. B. um UID zu Usernamen aufzulösen), historisch stand dort früher tatsächlich der Hash.
2. Es verhindert einen interaktiven Login für diesen Account — typisch für Systemaccounts wie `www-data` oder `nobody`, die Dienste ausführen, sich aber nicht einloggen sollen dürfen.

**Übung 2**

1. `/etc` enthält Konfigurationsdateien, `/usr` enthält (meist statische) Programme und Bibliotheken. `/var` steht für *variable data* — Inhalte, die sich zur Laufzeit ständig ändern, wie eben Logs.
2. `tail -f` folgt der Datei kontinuierlich und zeigt neue Zeilen sofort an, ohne dass der Befehl erneut ausgeführt werden muss.

**Übung 3**

1. Dateien unter `/proc` sind virtuell und existieren nicht auf der Festplatte; ihr Inhalt wird vom Kernel bei jedem Zugriff dynamisch erzeugt, daher liefert das Dateisystem keine reale Größe.
2. Das Verzeichnis verschwindet automatisch, da es lediglich eine Live-Repräsentation des laufenden Prozesses im Kernel ist.

**Übung 4**

1. Bei `ls -l` steht `b` für ein block device (z. B. Festplatten, blockweiser Zugriff) und `c` für ein character device (z. B. Terminals, byteweiser Zugriff) an erster Stelle der Berechtigungsspalte.
2. `/dev/null` verwirft jede geschriebene Eingabe sofort und liefert bei Lesezugriff immer sofort ein EOF (End of File) — es speichert nichts.

**Übung 5**

1. Ein Hard Link ist ein zweiter Verzeichniseintrag, der auf dieselbe Inode zeigt wie das Original — beide Namen sind gleichwertig. Ein Symbolic Link ist dagegen eine eigene, kleine Datei mit eigener Inode, die lediglich den *Pfad* zur Zieldatei speichert.
2. Solange mindestens ein Hard Link auf eine Inode existiert, bleiben die Daten erhalten; das Löschen von `original.txt` entfernt nur einen von mehreren Verweisen. Ein Symbolic Link verweist dagegen auf den *Namen* `original.txt`, der nach dem Löschen nicht mehr existiert — der Link wird "broken" bzw. "dangling".
3. Hard Links können sich nicht über Dateisystemgrenzen hinweg erstrecken und in der Regel nicht auf Verzeichnisse zeigen, da beides die Konsistenz des Dateisystems gefährden würde. Symbolic Links können sowohl auf Verzeichnisse als auch auf Ziele in anderen Dateisystemen (oder auf nicht existierende Ziele) verweisen.

</details>