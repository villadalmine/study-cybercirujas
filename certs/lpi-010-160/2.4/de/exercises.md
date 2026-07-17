# LPI Linux Essentials (010-160, v1.6) – Thema 2.4: Creating, Moving and Deleting Files

Quelle zur Vertiefung: https://learning.lpi.org/en/learning-materials/010-160/2/2.4/

## Übung 1: Directories mit `mkdir` anlegen

1. Öffne ein Terminal und wechsle in dein Home-Directory: `cd ~`
2. Lege ein neues Directory namens `projekt` an: `mkdir projekt`
3. Wechsle hinein: `cd projekt`
4. Versuche, eine mehrstufige Pfadstruktur direkt anzulegen: `mkdir daten/2024/quartal1`
5. Wiederhole den Versuch mit der Option `-p`: `mkdir -p daten/2024/quartal1`
6. Kontrolliere das Ergebnis: `ls -R`

**Fragen:**
- Warum schlägt Schritt 4 fehl, während Schritt 5 erfolgreich ist?
- Was genau bewirkt die Option `-p` bei `mkdir`?

## Übung 2: Dateien mit `touch` erstellen

1. Erstelle im Directory `projekt` drei leere Dateien in einem Befehl: `touch bericht.txt notizen.txt todo.txt`
2. Zeige die Zeitstempel an: `ls -l`
3. Warte kurz (mindestens eine Minute) und führe erneut aus: `touch bericht.txt`
4. Vergleiche den Zeitstempel von `bericht.txt` vor und nach diesem zweiten Aufruf: `ls -l bericht.txt`

**Fragen:**
- Was passiert bei `touch`, wenn die angegebene Datei bereits existiert?
- Welche zwei Zeitstempel einer Datei aktualisiert `touch` standardmäßig?

## Übung 3: Dateien kopieren mit `cp`

1. Erstelle eine Sicherungskopie von `bericht.txt`: `cp bericht.txt bericht.txt.bak`
2. Kopiere `notizen.txt` in das Directory `daten/2024/quartal1/`: `cp notizen.txt daten/2024/quartal1/`
3. Versuche, das gesamte Directory `daten` ohne Zusatzoption zu kopieren: `cp daten daten-backup`
4. Wiederhole den Kopiervorgang mit der Option `-r` (recursive): `cp -r daten daten-backup`
5. Überschreibe `todo.txt` mit sich selbst unter Verwendung der Option `-i` (interactive): `cp -i todo.txt todo.txt`

**Fragen:**
- Welche Meldung gibt `cp` in Schritt 3 aus, und warum ist `-r` bei Directories zwingend nötig?
- Wofür sorgt die Option `-i` bei `cp`, und wann ist sie sinnvoll?

## Übung 4: Dateien und Directories verschieben/umbenennen mit `mv`

1. Benenne `bericht.txt.bak` um in `bericht_alt.txt`: `mv bericht.txt.bak bericht_alt.txt`
2. Verschiebe `bericht_alt.txt` in das Directory `daten-backup/`: `mv bericht_alt.txt daten-backup/`
3. Benenne das gesamte Directory `daten-backup` um in `archiv`: `mv daten-backup archiv`
4. Verschiebe mehrere Dateien gleichzeitig in dieses Directory: `mv todo.txt notizen.txt archiv/`

**Fragen:**
- Worin unterscheidet sich `mv` von `cp`, wenn ein ganzes Directory verschoben wird – braucht `mv` dafür ebenfalls die Option `-r`?
- Was passiert, wenn das Ziel von `mv` ein existierendes Directory ist, im Vergleich dazu, wenn es eine existierende Datei ist?

## Übung 5: Dateien und Directories löschen mit `rm` und `rmdir`

1. Versuche, das (nun leere) Directory zu löschen: `rmdir daten/2024/quartal1`
2. Versuche anschließend, das nicht-leere Directory `daten` mit `rmdir daten` zu löschen.
3. Lösche `daten` stattdessen rekursiv samt Inhalt: `rm -r daten`
4. Lösche eine einzelne Datei mit Bestätigungsnachfrage: `rm -i archiv/todo.txt`
5. Lösche das gesamte Directory `archiv` ohne Rückfrage: `rm -rf archiv`

**Fragen:**
- Warum funktioniert `rmdir` nur bei leeren Directories, während `rm -r` auch bei gefüllten funktioniert?
- Welche Risiken birgt die Kombination `rm -rf`, und warum ist besondere Vorsicht geboten?

## Übung 6: Wildcards für Batch-Operationen

1. Erstelle vier Testdateien: `touch datei1.log datei2.log datei3.txt datei4.txt`
2. Liste alle `.log`-Dateien mit einem Wildcard auf: `ls *.log`
3. Kopiere alle `.txt`-Dateien in ein neues Directory: `mkdir texte && cp *.txt texte/`
4. Lösche alle `.log`-Dateien auf einmal: `rm *.log`
5. Verwende das `?`-Wildcard, um `datei` gefolgt von genau einem Zeichen und `.txt` zu finden: `ls datei?.txt`

**Fragen:**
- Welchen Unterschied gibt es zwischen den Wildcards `*` und `?` in der Shell?
- Was würde `rm *` in einem Directory bewirken, und warum ist vor der Ausführung besondere Vorsicht geboten?

<details>
<summary>Antworten</summary>

**Übung 1**
- Schritt 4 schlägt fehl, weil `mkdir` standardmäßig nur die letzte Ebene eines Pfades anlegt – die übergeordneten Directories `daten` und `daten/2024` existieren noch nicht, daher meldet `mkdir` einen Fehler ("No such file or directory").
- Die Option `-p` (parents) lässt `mkdir` alle fehlenden übergeordneten Directories im Pfad automatisch mit anlegen, ohne Fehler zu melden, falls ein Directory bereits existiert.

**Übung 2**
- Existiert die Datei bereits, legt `touch` keine neue Datei an, sondern aktualisiert nur ihre Zeitstempel auf die aktuelle Zeit.
- `touch` aktualisiert standardmäßig die access time (atime) und die modification time (mtime) der Datei.

**Übung 3**
- `cp` meldet, dass `daten` ein Directory ist ("omitting directory") und ohne die Option `-r` nicht kopiert werden kann, da `cp` standardmäßig nur einzelne Dateien kopiert.
- `-r` (recursive) weist `cp` an, ein Directory samt seinem gesamten Inhalt (Unterdirectories und Dateien) zu kopieren. `-i` fragt vor dem Überschreiben einer bereits existierenden Zieldatei nach Bestätigung und verhindert so versehentlichen Datenverlust.

**Übung 4**
- `mv` benötigt keine Option `-r`, um ein Directory zu verschieben oder umzubenennen: Da dabei (im selben Filesystem) nur der Verzeichniseintrag geändert wird und keine Daten physisch kopiert werden, funktioniert es unabhängig davon, ob es sich um eine Datei oder ein Directory handelt.
- Ist das Ziel ein existierendes Directory, wird die Quelle *hinein* verschoben (unter ihrem ursprünglichen Namen). Ist das Ziel eine existierende Datei, wird diese ohne Rückfrage überschrieben (außer man verwendet `-i`).

**Übung 5**
- `rmdir` löscht ausschließlich leere Directories als Sicherheitsmechanismus; enthält das Directory noch Dateien oder Unterdirectories, verweigert es die Löschung. `rm -r` hingegen löscht rekursiv den gesamten Inhalt und danach das Directory selbst.
- `rm -rf` löscht rekursiv (`-r`) und ohne jede Rückfrage (`-f`, force) – auch schreibgeschützte Dateien werden ohne Bestätigung entfernt. Ein Tippfehler im Pfad kann dadurch zu unwiederbringlichem Datenverlust führen, da es keinen Papierkorb gibt.

**Übung 6**
- `*` steht für eine beliebige Zeichenfolge beliebiger Länge (auch leer), während `?` genau ein einzelnes beliebiges Zeichen ersetzt.
- `rm *` löscht alle Dateien im aktuellen Directory (die nicht mit einem Punkt beginnen), ohne Rückfrage. Da die Shell den Wildcard vor der Ausführung expandiert, sieht man die Liste der betroffenen Dateien vorher nicht mehr – daher sollte man vorher immer mit `ls *` prüfen, was tatsächlich betroffen wäre.

</details>