# Thema 5.3: Managing File Permissions and Ownership

*LPI Linux Essentials, Exam 010-160 (Version 1.6) — Referenz: [learning.lpi.org/en/learning-materials/010-160/5/5.3/](https://learning.lpi.org/en/learning-materials/010-160/5/5.3/)*

---

## Übung 1: Permissions mit `ls -l` lesen

1. Öffne ein Terminal und wechsle in dein Home-Verzeichnis:
   ```
   cd ~
   ```
2. Lege eine Testdatei an:
   ```
   touch bericht.txt
   ```
3. Zeige die Details der Datei an:
   ```
   ls -l bericht.txt
   ```
   Die Ausgabe sieht ungefähr so aus:
   ```
   -rw-r--r-- 1 anna anna 0 12. Jul 10:00 bericht.txt
   ```
4. Zerlege die erste Spalte gedanklich in ihre Bestandteile: das erste Zeichen (Dateityp), gefolgt von drei Dreiergruppen für **owner**, **group** und **others**, jede mit den Positionen `r` (read), `w` (write) und `x` (execute).

**Frage 1.1:** Welche drei permission-Klassen unterscheidet Linux bei jeder Datei, und in welcher Reihenfolge erscheinen sie in der Ausgabe von `ls -l`?

**Frage 1.2:** Was bedeutet ein `-` anstelle eines `r`, `w` oder `x` an einer bestimmten Position?

---

## Übung 2: `chmod` im symbolic mode

1. Entferne das execute-Recht für alle, füge es dann gezielt für den owner hinzu:
   ```
   chmod u+x bericht.txt
   ```
2. Prüfe das Ergebnis:
   ```
   ls -l bericht.txt
   ```
3. Entferne das read-Recht für group und others gleichzeitig:
   ```
   chmod go-r bericht.txt
   ```
4. Setze die permissions für owner und group explizit auf read+write, und entziehe others jeden Zugriff:
   ```
   chmod ug=rw,o= bericht.txt
   ```

**Frage 2.1:** Worin unterscheiden sich die Operatoren `+`, `-` und `=` im symbolic mode von `chmod`?

**Frage 2.2:** Wie würdest du mit einem einzigen `chmod`-Befehl im symbolic mode allen drei Klassen (owner, group, others) das execute-Recht entziehen, ohne die read/write-Rechte zu verändern?

---

## Übung 3: `chmod` im octal (numeric) mode

1. Rufe dir die Werte ins Gedächtnis: `read = 4`, `write = 2`, `execute = 1`. Jede Klasse ergibt sich aus der Summe der gewünschten Rechte.
2. Setze `bericht.txt` auf read+write für den owner und nichts für group/others:
   ```
   chmod 600 bericht.txt
   ```
3. Prüfe das Ergebnis mit `ls -l bericht.txt`.
4. Lege ein Verzeichnis an und vergib eine typische Verzeichnis-permission:
   ```
   mkdir projekt
   chmod 755 projekt
   ls -ld projekt
   ```

**Frage 3.1:** Welche octal-Zahl entspricht der symbolischen Darstellung `rwxr-xr-x`, und wie kommt sie rechnerisch zustande?

**Frage 3.2:** Ein Kollege führt `chmod 640 datei.sh` aus. Welche Rechte hat danach jeweils owner, group und others?

---

## Übung 4: Execute-Recht bei Verzeichnissen

1. Lege ein Verzeichnis mit einer Datei darin an:
   ```
   mkdir testverzeichnis
   touch testverzeichnis/notiz.txt
   ```
2. Entziehe dir selbst das execute-Recht auf dem Verzeichnis (owner):
   ```
   chmod u-x testverzeichnis
   ```
3. Versuche, in das Verzeichnis zu wechseln:
   ```
   cd testverzeichnis
   ```
   Beobachte die Fehlermeldung.
4. Stelle das execute-Recht wieder her und wiederhole den Wechsel:
   ```
   chmod u+x testverzeichnis
   cd testverzeichnis
   ```

**Frage 4.1:** Warum benötigt man das execute-Recht auf einem Verzeichnis, um hineinzuwechseln oder auf darin enthaltene Dateien zuzugreifen, obwohl man das Verzeichnis nicht im klassischen Sinn "ausführt"?

**Frage 4.2:** Reicht das read-Recht allein aus, um mit `cd` in ein Verzeichnis zu wechseln? Begründe.

---

## Übung 5: Ownership ändern mit `chown` und `chgrp`

1. Prüfe die aktuellen owner- und group-Zuordnungen:
   ```
   ls -l bericht.txt
   ```
2. Ändere den owner der Datei (erfordert in der Regel `sudo`):
   ```
   sudo chown root bericht.txt
   ```
3. Ändere die group-Zuordnung separat:
   ```
   sudo chgrp adm bericht.txt
   ```
4. Ändere owner und group gleichzeitig in einem Befehl:
   ```
   sudo chown anna:anna bericht.txt
   ```

**Frage 5.1:** Warum ist zum Ändern des owners einer Datei normalerweise `sudo` bzw. root-Berechtigung nötig, während man die eigenen file permissions per `chmod` ohne `sudo` ändern kann?

**Frage 5.2:** Was ist der Unterschied zwischen `chown` und `chgrp`, und wie lässt sich beides mit einem einzigen `chown`-Aufruf erledigen?

---

## Übung 6: Standard-permissions mit `umask` verstehen

1. Zeige den aktuellen umask-Wert an:
   ```
   umask
   ```
2. Erstelle eine neue Datei und prüfe ihre permissions:
   ```
   touch neu.txt
   ls -l neu.txt
   ```
3. Erstelle ein neues Verzeichnis und prüfe dessen permissions:
   ```
   mkdir neuesverz
   ls -ld neuesverz
   ```
4. Setze den umask für die aktuelle Shell-Sitzung strenger und wiederhole den Test:
   ```
   umask 027
   touch streng.txt
   ls -l streng.txt
   ```

**Frage 6.1:** Wie berechnet man die resultierenden permissions einer neu erstellten Datei aus dem Basiswert `666` (Dateien) bzw. `777` (Verzeichnisse) und dem umask-Wert?

**Frage 6.2:** Warum hat eine mit `touch` neu erstellte Datei niemals automatisch das execute-Recht gesetzt, selbst wenn `umask 000` gilt — im Unterschied zu einem neu erstellten Verzeichnis?

---

## Übung 7: Sonderfälle erkennen — setuid, setgid, sticky bit

1. Betrachte ein bekanntes Beispiel für setuid:
   ```
   ls -l /usr/bin/passwd
   ```
   Achte auf das `s` anstelle von `x` in der owner-Spalte.
2. Betrachte ein bekanntes Beispiel für das sticky bit:
   ```
   ls -ld /tmp
   ```
   Achte auf das `t` anstelle von `x` in der others-Spalte.

**Frage 7.1:** Was bewirkt das sticky bit auf einem gemeinsam genutzten Verzeichnis wie `/tmp`?

**Frage 7.2:** Wofür wird setuid bei einem ausführbaren Programm wie `passwd` benötigt?

---

<details>
<summary><strong>Lösungen</strong></summary>

**1.1** Die drei Klassen sind **owner** (Eigentümer der Datei), **group** (die zugeordnete Gruppe) und **others** (alle übrigen Benutzer). Sie erscheinen in dieser Reihenfolge direkt nach dem Dateityp-Zeichen, jeweils als Dreiergruppe `rwx`.

**1.2** Ein `-` zeigt an, dass das jeweilige Recht (read, write oder execute) für die betreffende Klasse an dieser Position **nicht** vergeben ist.

**2.1** `+` fügt das angegebene Recht hinzu, ohne andere Rechte zu verändern. `-` entfernt gezielt ein Recht. `=` setzt die Rechte der genannten Klasse exakt auf den angegebenen Wert und überschreibt dabei alle vorher gesetzten Rechte dieser Klasse.

**2.2** `chmod a-x bericht.txt` (oder gleichbedeutend `chmod ugo-x bericht.txt`) entzieht owner, group und others das execute-Recht, ohne read/write anzutasten.

**3.1** `755`. Owner erhält `rwx` = 4+2+1 = 7, group erhält `r-x` = 4+0+1 = 5, others erhält `r-x` = 4+0+1 = 5.

**3.2** `640` ergibt: owner = `rw-` (read+write, kein execute), group = `r--` (nur read), others = `---` (keine Rechte).

**4.1** Das execute-Recht auf einem Verzeichnis steuert, ob man in das Verzeichnis hineinwechseln (`cd`) und auf die darin liegenden Einträge (Dateien, Unterverzeichnisse) zugreifen darf — es ist bei Verzeichnissen also gleichbedeutend mit "Durchsuchen/Betreten dürfen", nicht mit "ausführen" im Sinne eines Programms.

**4.2** Nein. Das read-Recht erlaubt lediglich, den Inhalt des Verzeichnisses aufzulisten (z. B. mit `ls`), nicht aber hineinzuwechseln oder auf einzelne Dateien darin zuzugreifen. Dafür ist zusätzlich das execute-Recht erforderlich.

**5.1** Das Ändern des owners betrifft die Zuordnung der Datei zu einem Benutzerkonto und könnte missbraucht werden, um Eigentum an fremden Dateien zu übernehmen oder Quota-/Accounting-Regeln zu umgehen. Deshalb ist dieser Vorgang auf root beschränkt. `chmod` hingegen ändert nur die Zugriffsrechte der bereits eigenen Datei, was der owner selbst kontrollieren darf.

**5.2** `chown` ändert den owner (optional zusätzlich die group über `owner:group`), während `chgrp` ausschließlich die group ändert. Mit `sudo chown anna:anna datei` lassen sich owner und group in einem Schritt setzen.

**6.1** Man bildet die bitweise Differenz (genauer: die Negation des umask wird mit dem Basiswert UND-verknüpft) zwischen Basiswert und umask. Praktisch: Bei umask `022` ergibt sich für Dateien `666 - 022 = 644` und für Verzeichnisse `777 - 022 = 755`. Bei umask `027` ergibt sich für Dateien `666` ohne die durch `027` maskierten Bits = `640`, für Verzeichnisse `750`.

**6.2** Der umask wirkt nur einschränkend auf den jeweiligen Basiswert; für Dateien ist der Basiswert `666` (kein execute enthalten), daher kann durch umask kein execute-Bit entstehen, das dort gar nicht vorgesehen ist. Verzeichnisse haben dagegen den Basiswert `777`, der execute standardmäßig einschließt, damit sie durchsucht werden können.

**7.1** Das sticky bit auf einem Verzeichnis sorgt dafür, dass nur der owner einer Datei (oder root) diese Datei innerhalb des Verzeichnisses löschen oder umbenennen kann — selbst wenn andere Benutzer write-Recht auf das Verzeichnis haben. Das schützt in gemeinsam genutzten Verzeichnissen wie `/tmp` die Dateien anderer Benutzer.

**7.2** setuid lässt ein Programm beim Ausführen mit den Rechten des owners der Datei laufen statt mit den Rechten des aufrufenden Benutzers. `passwd` benötigt dies, damit ein normaler Benutzer sein eigenes Passwort ändern kann, obwohl dafür Schreibzugriff auf eine root-geschützte Systemdatei nötig ist.

</details>