# Übungen: Using Directories and Listing Files (Thema 2.3)

**Quelle (Referenz, keine wörtliche Übernahme):** https://learning.lpi.org/en/learning-materials/010-160/2/2.3/

---

## Übung 1 — Navigation im Filesystem: `pwd` und `cd`

1. Öffne ein Terminal und gib `pwd` ein, um das aktuelle **working directory** anzuzeigen.
2. Wechsle mit `cd /etc` in ein absolutes Verzeichnis und prüfe mit `pwd`, wo du gelandet bist.
3. Kehre mit `cd` (ohne Argument) direkt in dein **home directory** zurück.
4. Wechsle mit `cd ..` eine Ebene nach oben (Parent Directory) und mit `cd .` bleibe im aktuellen Verzeichnis (keine Änderung).
5. Nutze `cd -`, um zum zuletzt besuchten Verzeichnis zurückzuspringen.
6. Wechsle mit `cd ~/Documents` (relativ zum home directory über die Tilde `~`) in ein Unterverzeichnis, falls vorhanden, sonst mit `cd ~`.

> **Verständnisfrage 1:** Was ist der Unterschied zwischen einem *absolute path* (z. B. `/etc/passwd`) und einem *relative path* (z. B. `../logs`)?
>
> **Verständnisfrage 2:** Was bewirken die Sonderzeichen `.`, `..` und `~` jeweils bei der Pfadangabe?

---

## Übung 2 — Verzeichnisse anlegen und entfernen: `mkdir` und `rmdir`

1. Wechsle in dein home directory (`cd ~`) und lege ein neues Verzeichnis an: `mkdir uebung23`.
2. Wechsle hinein (`cd uebung23`) und versuche, verschachtelte Verzeichnisse in einem Schritt zu erstellen: `mkdir projekt/daten/2026`.
3. Beobachte die Fehlermeldung ("No such file or directory") — dies passiert, weil die Parent Directories nicht existieren.
4. Wiederhole den Schritt mit der Option `-p`: `mkdir -p projekt/daten/2026`, die fehlende Parent Directories automatisch mit anlegt.
5. Entferne mit `rmdir` ein **leeres** Verzeichnis, z. B. `rmdir projekt/daten/2026`.
6. Versuche anschließend `rmdir projekt` und beobachte, dass dies fehlschlägt, solange das Verzeichnis noch Unterverzeichnisse enthält.

> **Verständnisfrage 3:** Wofür steht die Option `-p` bei `mkdir`, und warum ist sie beim Anlegen von verschachtelten Pfaden nützlich?
>
> **Verständnisfrage 4:** Warum funktioniert `rmdir` nicht bei nicht-leeren Verzeichnissen? Welcher Befehl wäre stattdessen nötig, um ein Verzeichnis samt Inhalt zu löschen?

---

## Übung 3 — Dateien auflisten: `ls` und wichtige Optionen

1. Liste im Verzeichnis `~/uebung23` den Inhalt mit `ls` auf.
2. Zeige mit `ls -a` **alle** Dateien inklusive versteckter Dateien (die mit `.` beginnen) an.
3. Zeige mit `ls -l` das **long listing format** an (Permissions, Owner, Group, Size, Datum).
4. Kombiniere Optionen: `ls -la`, um versteckte Dateien im long format zu sehen.
5. Nutze `ls -F`, um jedem Eintrag ein Symbol anzuhängen, das den Dateityp anzeigt (z. B. `/` für Verzeichnisse, `*` für ausführbare Dateien, `@` für symbolic links).
6. Nutze `ls -d */`, um nur Verzeichnisse (nicht deren Inhalt) aufzulisten.
7. Erstelle eine tiefere Struktur (`mkdir -p a/b/c`) und liste sie rekursiv mit `ls -R` auf.
8. Zeige mit `ls -i` die **inode**-Nummer jeder Datei an.

> **Verständnisfrage 5:** Welche Optionskombination von `ls` würdest du verwenden, um versteckte Dateien mit vollständigen Details (Rechte, Größe, Datum) anzuzeigen?
>
> **Verständnisfrage 6:** Wofür steht das Symbol `/` am Ende eines Eintrags bei `ls -F`, und wofür steht `@`?

---

## Übung 4 — Dateitypen erkennen

1. Erzeuge in `~/uebung23` eine reguläre Datei: `touch datei.txt`.
2. Erzeuge einen **symbolic link** darauf: `ln -s datei.txt link.txt`.
3. Führe `ls -l` aus und beachte das erste Zeichen jeder Zeile: `-` für reguläre Dateien, `d` für Verzeichnisse, `l` für Links.
4. Prüfe mit dem Befehl `file datei.txt` und `file link.txt`, wie das System den Dateityp jeweils benennt.
5. Liste die Gerätedateien im Verzeichnis `/dev` mit `ls -l /dev | head -n 20` auf und suche nach Zeilen, die mit `b` (block device) oder `c` (character device) beginnen.
6. Suche mit `ls -l /dev | grep '^p'` nach einer **named pipe (FIFO)**, sofern vorhanden.

> **Verständnisfrage 7:** Welcher Buchstabe erscheint am Zeilenanfang von `ls -l` bei einem *symbolic link*, und was unterscheidet ein block device von einem character device?

---

## Übung 5 — Versteckte Dateien (dotfiles)

1. Wechsle in dein home directory (`cd ~`) und liste mit `ls -a` alle dotfiles auf (z. B. `.bashrc`, `.bash_history`, `.config`).
2. Erstelle in `~/uebung23` eine eigene versteckte Datei: `touch .geheim`.
3. Bestätige mit `ls` (ohne `-a`), dass `.geheim` **nicht** angezeigt wird.
4. Bestätige mit `ls -a`, dass `.geheim` jetzt sichtbar ist.

> **Verständnisfrage 8:** Warum werden Dateien, deren Name mit einem Punkt beginnt, standardmäßig von `ls` ausgeblendet, und wie nennt man diese Konvention?

---

## Übung 6 — Tab Completion und Command History

1. Tippe `cd uebu` und drücke die **Tab**-Taste, um den Verzeichnisnamen automatisch vervollständigen zu lassen.
2. Tippe `ls -l /etc/pass` und drücke Tab zweimal, um mögliche Vervollständigungen anzuzeigen, falls mehrere Treffer existieren.
3. Führe `history` aus, um die Liste der zuletzt ausgeführten Befehle zu sehen.
4. Nutze die Pfeiltaste **nach oben**, um einen früheren Befehl erneut aufzurufen, und führe ihn mit Enter erneut aus.

> **Verständnisfrage 9:** Welchen praktischen Vorteil bietet Tab Completion beim Arbeiten mit langen Pfaden?

---

<details>
<summary><strong>Lösungen anzeigen</strong></summary>

**Antwort 1:** Ein *absolute path* beginnt immer beim root directory `/` und beschreibt den vollständigen Pfad unabhängig vom aktuellen Standort (z. B. `/etc/passwd`). Ein *relative path* wird ausgehend vom aktuellen working directory interpretiert (z. B. `../logs` bedeutet: eine Ebene hoch, dann in `logs`).

**Antwort 2:** `.` steht für das aktuelle Verzeichnis, `..` für das Parent Directory (eine Ebene höher), und `~` ist eine Abkürzung für das home directory des aktuellen Users.

**Antwort 3:** Die Option `-p` (parents) sorgt dafür, dass `mkdir` alle fehlenden übergeordneten Verzeichnisse im angegebenen Pfad automatisch mit erstellt, statt einen Fehler auszugeben, wenn Zwischenverzeichnisse fehlen.

**Antwort 4:** `rmdir` löscht ausschließlich leere Verzeichnisse als Sicherheitsmaßnahme gegen versehentlichen Datenverlust. Um ein Verzeichnis samt Inhalt zu löschen, wird `rm -r` (recursive) verwendet.

**Antwort 5:** `ls -la` (bzw. `ls -al`) zeigt versteckte Dateien (`-a`) im long listing format (`-l`) mit allen Details an.

**Antwort 6:** `/` markiert ein Verzeichnis, `@` markiert einen symbolic link. Weitere Symbole bei `ls -F` sind z. B. `*` für ausführbare Dateien und `|` für named pipes.

**Antwort 7:** Ein symbolic link wird bei `ls -l` mit `l` am Zeilenanfang markiert. Ein block device (`b`) überträgt Daten blockweise mit gepuffertem Zugriff (z. B. Festplatten), während ein character device (`c`) Daten zeichenweise/unbuffered überträgt (z. B. Terminals, serielle Schnittstellen).

**Antwort 8:** Dateien mit einem führenden Punkt gelten als *hidden files* (dotfiles) und werden standardmäßig ausgeblendet, um Konfigurationsdateien und Systemdateien nicht bei jeder normalen Auflistung anzuzeigen. Um sie zu sehen, ist die Option `-a` (all) bei `ls` nötig.

**Antwort 9:** Tab Completion reduziert Tippfehler und Zeitaufwand, da lange oder komplexe Pfad- und Dateinamen automatisch vervollständigt werden, sobald genügend eindeutige Zeichen eingegeben wurden.

</details>